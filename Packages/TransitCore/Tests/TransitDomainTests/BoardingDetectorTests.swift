import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BoardingDetector")
struct BoardingDetectorTests {
    private let detector = BoardingDetector()
    private let t0 = Date(timeIntervalSinceReferenceDate: 770_000_000)

    /// Test station near downtown Chicago (Clark/Lake): id 40380.
    /// Coordinates roughly accurate but we don't need them precise; we
    /// just need two distinct catalog entries to exercise the "closest
    /// wins" branch.
    private static let stationA = LStation(
        id: 40380,
        name: "Clark/Lake",
        latitude: 41.885737,
        longitude: -87.630886,
        servedLines: [.blue, .brown, .green, .orange, .pink, .purple]
    )

    /// A second station ~250m away — far enough that only one is within
    /// the default 150m radius, but close enough that we can manufacture
    /// a "two stations in radius" scenario for the closest-wins test.
    private static let stationB = LStation(
        id: 40260,
        name: "State/Lake",
        latitude: 41.885983,
        longitude: -87.627691,
        servedLines: [.red]
    )

    private func location(
        lat: Double,
        lon: Double,
        recordedAt: Date? = nil
    ) -> LastKnownLocation {
        LastKnownLocation(
            latitude: lat,
            longitude: lon,
            recordedAt: recordedAt ?? Date(timeIntervalSinceReferenceDate: 769_999_000),
            source: .foreground
        )
    }

    // MARK: - Positive cases

    @Test func stationaryToAutomotiveWithinRadiusEmitsEvent() {
        // Stand exactly on top of station A (≪150m).
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)
        #expect(event?.observedAt == t0)
    }

    @Test func walkingToAutomotiveAtStationEmitsEvent() {
        let event = detector.detect(
            previousMotion: .walking,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)
    }

    @Test func walkingToCyclingAtStationEmitsEvent() {
        // Cycling is included in the boarding set because the classifier
        // wobbles between cycling and automotive at low speeds.
        let event = detector.detect(
            previousMotion: .walking,
            currentMotion: .cycling,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)
    }

    @Test func stationaryToAutomotiveAt100mFromStationStillCounts() {
        // Move ~100m east of station A — still well within the 150m
        // default radius.
        let east100 = offsetMeters(
            lat: Self.stationA.latitude,
            lon: Self.stationA.longitude,
            northing: 0,
            easting: 100
        )
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: east100.lat, lon: east100.lon),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)
    }

    // MARK: - Negative cases

    @Test func automotiveToAutomotiveCarDriveByEmitsNothing() {
        // Driving past the station — no transition into vehicle motion.
        let event = detector.detect(
            previousMotion: .automotive,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func stationaryToAutomotiveOutsideRadiusEmitsNothing() {
        // ~500m south of the station — well outside the 150m radius.
        let south500 = offsetMeters(
            lat: Self.stationA.latitude,
            lon: Self.stationA.longitude,
            northing: -500,
            easting: 0
        )
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: south500.lat, lon: south500.lon),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func boardingWithoutLocationEmitsNothing() {
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: nil,
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func boardingTransitionWithEmptyCatalogEmitsNothing() {
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func stationaryToStationaryEmitsNothing() {
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .stationary,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func walkingToWalkingEmitsNothing() {
        // The user kept walking past — they didn't board.
        let event = detector.detect(
            previousMotion: .walking,
            currentMotion: .walking,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func unknownPreviousMotionEmitsNothing() {
        // Detector requires a confident "non-vehicle" frame to call a
        // transition. `.unknown` doesn't count.
        let event = detector.detect(
            previousMotion: .unknown,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func unknownCurrentMotionEmitsNothing() {
        let event = detector.detect(
            previousMotion: .walking,
            currentMotion: .unknown,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    @Test func runningToAutomotiveIsNotABoardingTransition() {
        // Running is conceptually "in motion" but the detector only
        // recognizes stationary/walking as the pre-boarding state.
        // Running → automotive is an unusual phase that we'd rather
        // miss than misclassify.
        let event = detector.detect(
            previousMotion: .running,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA],
            now: t0
        )
        #expect(event == nil)
    }

    // MARK: - Closest-wins

    @Test func twoStationsWithinRadiusPicksClosest() {
        // Place the user 50m east of station A (~283m from B). Only A
        // is within 150m, so A wins trivially.
        let east50 = offsetMeters(
            lat: Self.stationA.latitude,
            lon: Self.stationA.longitude,
            northing: 0,
            easting: 50
        )
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: east50.lat, lon: east50.lon),
            stationCatalog: [Self.stationB, Self.stationA],
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)
    }

    @Test func twoStationsBothInRadiusPicksClosest() {
        // Use a wider radius so both A and B fall inside. The user is
        // positioned exactly on A, so A wins regardless of catalog
        // ordering.
        let event = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationB, Self.stationA],
            maxRadiusMeters: 500,
            now: t0
        )
        #expect(event != nil)
        #expect(event?.stationId == Self.stationA.id)

        // Flip the catalog order — closest-wins must not depend on it.
        let flipped = detector.detect(
            previousMotion: .stationary,
            currentMotion: .automotive,
            currentLocation: location(lat: Self.stationA.latitude, lon: Self.stationA.longitude),
            stationCatalog: [Self.stationA, Self.stationB],
            maxRadiusMeters: 500,
            now: t0
        )
        #expect(flipped?.stationId == Self.stationA.id)
    }

    // MARK: - Sendable / off-main

    @Test func detectorIsSendableAndCallableOffMain() async {
        // Detect on a detached task — exercise the Sendable surface.
        let detectorCopy = detector
        let stationA = Self.stationA
        let location = location(lat: stationA.latitude, lon: stationA.longitude)
        let now = t0
        let event = await Task.detached {
            detectorCopy.detect(
                previousMotion: .walking,
                currentMotion: .automotive,
                currentLocation: location,
                stationCatalog: [stationA],
                now: now
            )
        }.value
        #expect(event?.stationId == stationA.id)
    }

    // MARK: - Helpers

    /// Offset a coordinate by N meters along latitude (northing) and
    /// longitude (easting). Small-offset linear approximation — good
    /// enough for the ~100–500m tests we exercise here.
    private func offsetMeters(
        lat: Double,
        lon: Double,
        northing: Double,
        easting: Double
    ) -> (lat: Double, lon: Double) {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        return (
            lat: lat + northing / metersPerDegLat,
            lon: lon + easting / metersPerDegLon
        )
    }
}
