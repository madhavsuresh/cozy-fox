import Foundation
import Testing
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("BikeSpeedTracker")
struct BikeSpeedTrackerTests {
    private let homeAnchor = CommuteAnchors.Anchor(
        latitude: 41.965, longitude: -87.69, label: "Home"
    )
    private let workAnchor = CommuteAnchors.Anchor(
        latitude: 41.882, longitude: -87.62, label: "Work"
    )

    // Three stations: one ~100m from work, one >5km away, one ~100m from home.
    private let stationNearWork = LStation(
        id: 40100, name: "Near Work", latitude: 41.883, longitude: -87.621,
        servedLines: [.red]
    )
    private let stationNearHome = LStation(
        id: 40110, name: "Near Home", latitude: 41.966, longitude: -87.691,
        servedLines: [.brown]
    )
    private let stationFarAway = LStation(
        id: 40200, name: "Far Away", latitude: 42.06, longitude: -87.69,
        servedLines: [.purple]
    )

    private static func makeStore() -> WalkingDistanceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeSpeedTracker-\(UUID().uuidString).json")
        return WalkingDistanceStore(fileURL: url)
    }

    /// Seed a fresh MapKit cycling baseline for `(origin, station)`.
    private func seedBaseline(
        in store: WalkingDistanceStore,
        from origin: (lat: Double, lon: Double),
        toStation stationId: Int,
        expectedSeconds: TimeInterval
    ) {
        store.record(
            meters: 2_500,
            expectedTravelTime: expectedSeconds,
            origin: origin,
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: stationId),
            mode: .cycling
        )
    }

    // MARK: - Happy path

    @Test func rideStartedAtHomeEndedAtStationRecordsSample() {
        let store = Self.makeStore()
        seedBaseline(
            in: store,
            from: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            toStation: stationNearWork.id,
            expectedSeconds: 600  // 10 min cycling baseline
        )
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: start,
            anchors: anchors
        )
        #expect(tracker.hasPendingRideForTests)

        // Actually arrived in 12 min → ratio 720/600 = 1.2.
        let end = start.addingTimeInterval(720)
        let sample = tracker.recordRideEnd(
            at: (lat: stationNearWork.latitude, lon: stationNearWork.longitude),
            at: end,
            stations: [stationNearWork, stationNearHome, stationFarAway]
        )
        #expect(sample != nil)
        #expect(abs((sample?.ratio ?? 0) - 1.2) < 1e-9)
        #expect(!tracker.hasPendingRideForTests)
        #expect(store.cycleSpeedEstimate.count == 1)
        #expect(abs(store.cycleSpeedEstimate.mean - 1.2) < 1e-9)
    }

    // MARK: - Start gate

    @Test func startAwayFromAnchorIsNotRegistered() {
        let store = Self.makeStore()
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        tracker.recordRideStart(
            at: (lat: 42.5, lon: -87.0),  // far from anything
            at: Date(),
            anchors: anchors
        )
        #expect(!tracker.hasPendingRideForTests)
    }

    @Test func freshStartReplacesAbandonedPending() {
        let store = Self.makeStore()
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: first,
            anchors: anchors
        )
        // Second ride starts before the first ended.
        let second = first.addingTimeInterval(600)
        tracker.recordRideStart(
            at: (lat: workAnchor.latitude, lon: workAnchor.longitude),
            at: second,
            anchors: anchors
        )
        // Still has a pending ride — but it's the second one.
        #expect(tracker.hasPendingRideForTests)
    }

    // MARK: - End gates

    @Test func endFarFromAnyStationRecordsNothing() {
        let store = Self.makeStore()
        seedBaseline(
            in: store,
            from: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            toStation: stationNearWork.id,
            expectedSeconds: 600
        )
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: start,
            anchors: anchors
        )
        let sample = tracker.recordRideEnd(
            at: (lat: 42.5, lon: -87.0),  // far from any station
            at: start.addingTimeInterval(600),
            stations: [stationNearWork]
        )
        #expect(sample == nil)
        #expect(store.cycleSpeedEstimate.count == 0)
    }

    @Test func endWithoutFreshBaselineRecordsNothing() {
        // No baseline seeded for this anchor → station pair.
        let store = Self.makeStore()
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: start,
            anchors: anchors
        )
        let sample = tracker.recordRideEnd(
            at: (lat: stationNearWork.latitude, lon: stationNearWork.longitude),
            at: start.addingTimeInterval(600),
            stations: [stationNearWork]
        )
        #expect(sample == nil)
    }

    @Test func endAfterExpiryDropsPending() {
        let store = Self.makeStore()
        seedBaseline(
            in: store,
            from: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            toStation: stationNearWork.id,
            expectedSeconds: 600
        )
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: start,
            anchors: anchors
        )
        // 2h later — past the 90-min expiry.
        let sample = tracker.recordRideEnd(
            at: (lat: stationNearWork.latitude, lon: stationNearWork.longitude),
            at: start.addingTimeInterval(2 * 3600),
            stations: [stationNearWork]
        )
        #expect(sample == nil)
        #expect(!tracker.hasPendingRideForTests)
    }

    @Test func endWithoutPriorStartRecordsNothing() {
        let store = Self.makeStore()
        let tracker = BikeSpeedTracker(walkingStore: store)
        let sample = tracker.recordRideEnd(
            at: (lat: stationNearWork.latitude, lon: stationNearWork.longitude),
            at: Date(),
            stations: [stationNearWork]
        )
        #expect(sample == nil)
    }

    // MARK: - expireIfStale

    @Test func expireIfStaleSweepsAged() {
        let store = Self.makeStore()
        let tracker = BikeSpeedTracker(walkingStore: store)
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)

        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRideStart(
            at: (lat: homeAnchor.latitude, lon: homeAnchor.longitude),
            at: start,
            anchors: anchors
        )
        #expect(tracker.hasPendingRideForTests)
        tracker.expireIfStale(now: start.addingTimeInterval(2 * 3600))
        #expect(!tracker.hasPendingRideForTests)
    }

    // MARK: - Landmark resolution

    @Test func nearestAnchorPicksTheCloser() {
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        // Halfway between, slightly closer to work.
        let between = (lat: 41.884, lon: -87.621)
        let result = BikeSpeedTracker.nearestAnchor(to: between, anchors: anchors)
        #expect(result?.label == "Work")
    }

    @Test func nearestAnchorReturnsNilOutsideRadius() {
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let nowhere = (lat: 42.5, lon: -87.0)
        let result = BikeSpeedTracker.nearestAnchor(to: nowhere, anchors: anchors)
        #expect(result == nil)
    }
}
