import Foundation
import Testing
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("WalkSpeedTracker")
struct WalkSpeedTrackerTests {
    private let homeAnchor = CommuteAnchors.Anchor(latitude: 41.9, longitude: -87.65, label: "Home")
    private let workAnchor = CommuteAnchors.Anchor(latitude: 41.88, longitude: -87.63, label: "Work")

    private static func makeStore() -> WalkingDistanceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkSpeedTrackerTests-\(UUID().uuidString).json")
        return WalkingDistanceStore(fileURL: url)
    }

    private func recordBaseline(
        in store: WalkingDistanceStore,
        from anchor: CommuteAnchors.Anchor,
        stationId: Int,
        expectedSeconds: TimeInterval
    ) {
        store.record(
            meters: 400,
            expectedTravelTime: expectedSeconds,
            origin: (lat: anchor.latitude, lon: anchor.longitude),
            stationId: stationId
        )
    }

    // MARK: - Happy path

    @Test func regionExitFollowedByBoardingRecordsSample() async {
        let store = Self.makeStore()
        recordBaseline(in: store, from: homeAnchor, stationId: 40380, expectedSeconds: 360)
        let tracker = WalkSpeedTracker(walkingStore: store)

        let exitAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: exitAt)
        #expect(tracker.hasPendingWalkForTests)

        // User boards 5 min later — MapKit said 6 min → ratio 5/6.
        let boardAt = exitAt.addingTimeInterval(5 * 60)
        let sample = tracker.recordBoarding(stationId: 40380, at: boardAt)

        #expect(sample != nil)
        #expect(abs((sample?.ratio ?? 0) - (300.0 / 360.0)) < 1e-9)
        #expect(!tracker.hasPendingWalkForTests)
        #expect(store.walkSpeedEstimate.count == 1)
        #expect(abs(store.walkSpeedEstimate.mean - (300.0 / 360.0)) < 1e-9)
    }

    // MARK: - 45-min expiry

    @Test func boardingAfterExpiryDropsPendingAndRecordsNothing() async {
        let store = Self.makeStore()
        recordBaseline(in: store, from: homeAnchor, stationId: 40380, expectedSeconds: 360)
        let tracker = WalkSpeedTracker(walkingStore: store)

        let exitAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: exitAt)

        // 50 minutes later — outside the 45-min default expiry.
        let boardAt = exitAt.addingTimeInterval(50 * 60)
        let sample = tracker.recordBoarding(stationId: 40380, at: boardAt)

        #expect(sample == nil)
        #expect(!tracker.hasPendingWalkForTests)
        #expect(store.walkSpeedEstimate.count == 0)
    }

    // MARK: - No prior exit

    @Test func boardingWithoutPriorExitRecordsNothing() async {
        let store = Self.makeStore()
        recordBaseline(in: store, from: homeAnchor, stationId: 40380, expectedSeconds: 360)
        let tracker = WalkSpeedTracker(walkingStore: store)

        let sample = tracker.recordBoarding(
            stationId: 40380,
            at: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        #expect(sample == nil)
        #expect(store.walkSpeedEstimate.count == 0)
    }

    // MARK: - No fresh baseline

    @Test func boardingWithoutFreshCacheSkipsSample() async {
        let store = Self.makeStore()
        // No baseline recorded for stationId 40380.
        let tracker = WalkSpeedTracker(walkingStore: store)

        let exitAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: exitAt)
        let sample = tracker.recordBoarding(
            stationId: 40380,
            at: exitAt.addingTimeInterval(5 * 60)
        )
        #expect(sample == nil)
        // Pending walk got cleared so the next boarding doesn't pair with
        // this stale exit.
        #expect(!tracker.hasPendingWalkForTests)
        #expect(store.walkSpeedEstimate.count == 0)
    }

    // MARK: - Second exit overwrites the first

    @Test func laterExitOverwritesEarlierAbandonedExit() async {
        let store = Self.makeStore()
        recordBaseline(in: store, from: workAnchor, stationId: 40380, expectedSeconds: 240)
        let tracker = WalkSpeedTracker(walkingStore: store)

        let firstExit = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: firstExit)
        // 20 min later user comes back and re-exits from work this time.
        let secondExit = firstExit.addingTimeInterval(20 * 60)
        tracker.recordRegionExit(direction: .toHome, anchor: workAnchor, at: secondExit)

        // Boarding 4 min after the SECOND exit. The baseline is from
        // work, not home — the elapsed time is 4 min, expected 240 s.
        let boardAt = secondExit.addingTimeInterval(4 * 60)
        let sample = tracker.recordBoarding(stationId: 40380, at: boardAt)

        #expect(sample != nil)
        #expect(abs((sample?.actualSeconds ?? 0) - 240) < 1e-9)
        // Ratio = actual 240 / expected 240 = 1.0
        #expect(abs((sample?.ratio ?? 0) - 1.0) < 1e-9)
    }

    // MARK: - expireIfStale sweep

    @Test func expireIfStaleSweepsOldPendingWalk() {
        let store = Self.makeStore()
        let tracker = WalkSpeedTracker(walkingStore: store)

        let exitAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: exitAt)
        #expect(tracker.hasPendingWalkForTests)

        tracker.expireIfStale(now: exitAt.addingTimeInterval(50 * 60))
        #expect(!tracker.hasPendingWalkForTests)
    }

    @Test func expireIfStaleLeavesFreshPendingAlone() {
        let store = Self.makeStore()
        let tracker = WalkSpeedTracker(walkingStore: store)

        let exitAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        tracker.recordRegionExit(direction: .toWork, anchor: homeAnchor, at: exitAt)
        tracker.expireIfStale(now: exitAt.addingTimeInterval(10 * 60))
        #expect(tracker.hasPendingWalkForTests)
    }
}
