import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BusPatternGeometry")
struct BusPatternGeometryTests {
    private static let pattern = BusPattern(
        id: 4042,
        route: "65",
        directionName: "Westbound",
        lengthFeet: 3200,
        detourId: nil,
        points: [
            BusPatternPoint(sequence: 1, latitude: 41.8919, longitude: -87.6182,
                            patternDistanceFeet: 0, kindRaw: "S",
                            stopId: 456, stopName: "Grand & McClurg"),
            BusPatternPoint(sequence: 2, latitude: 41.8919, longitude: -87.6203,
                            patternDistanceFeet: 580, kindRaw: "W",
                            stopId: nil, stopName: nil),
            BusPatternPoint(sequence: 3, latitude: 41.8919, longitude: -87.6225,
                            patternDistanceFeet: 1160, kindRaw: "S",
                            stopId: 457, stopName: "Grand & Columbus"),
            BusPatternPoint(sequence: 4, latitude: 41.8919, longitude: -87.6260,
                            patternDistanceFeet: 2050, kindRaw: "W",
                            stopId: nil, stopName: nil),
            BusPatternPoint(sequence: 5, latitude: 41.8919, longitude: -87.6300,
                            patternDistanceFeet: 3200, kindRaw: "S",
                            stopId: 458, stopName: "Grand & Michigan"),
        ]
    )

    @Test("Map match returns high quality when GPS is on the pattern line")
    func mapMatchHighQualityOnLine() {
        // Exactly on the segment between point 2 (-87.6203) and point 3
        // (-87.6225) at lat 41.8919.
        let result = BusPatternGeometry.mapMatch(Self.pattern, lat: 41.8919, lon: -87.6214)
        #expect(result?.quality == .high)
        // Projected pdist should be roughly halfway between point 2 and point 3.
        if let projected = result?.projectedPatternDistanceFeet {
            #expect(projected > 800 && projected < 1000,
                    "expected ~870, got \(projected)")
        }
    }

    @Test("Map match returns unusable when GPS is far from the pattern")
    func mapMatchUnusableFarFromLine() {
        // ~500 m north of the pattern (still in Chicago grid but the
        // route doesn't go up there).
        let result = BusPatternGeometry.mapMatch(Self.pattern, lat: 41.8964, lon: -87.6214)
        #expect(result?.quality == .unusable)
    }

    @Test("Remaining feet is positive when vehicle is upstream of stop")
    func remainingFeetUpstream() {
        let remaining = BusPatternGeometry.remainingFeetAlongPattern(
            vehiclePatternDistance: 580,
            stopId: 457,  // pdist 1160
            pattern: Self.pattern
        )
        #expect(remaining == 580)
    }

    @Test("Remaining feet is negative when vehicle is past the stop")
    func remainingFeetCrossed() {
        let remaining = BusPatternGeometry.remainingFeetAlongPattern(
            vehiclePatternDistance: 2050,
            stopId: 457,  // pdist 1160
            pattern: Self.pattern
        )
        #expect(remaining == -890)
    }

    @Test("Remaining feet is nil when stop is not on the pattern")
    func remainingFeetUnknownStop() {
        let remaining = BusPatternGeometry.remainingFeetAlongPattern(
            vehiclePatternDistance: 500,
            stopId: 99999,
            pattern: Self.pattern
        )
        #expect(remaining == nil)
    }

    @Test("Pattern picker prefers an exact pid match over route+direction fallback")
    func patternPickerPrefersExactPid() {
        let altPattern = BusPattern(id: 9999, route: "65", directionName: "Westbound",
                                     lengthFeet: 1, detourId: nil,
                                     points: Self.pattern.points)
        let picked = BusPatternGeometry.pattern(
            for: 4042,
            route: "65",
            directionName: "Westbound",
            in: [altPattern, Self.pattern]
        )
        #expect(picked?.id == 4042)
    }

    @Test("Pattern picker falls back to route+direction when pid is missing")
    func patternPickerFallsBack() {
        let picked = BusPatternGeometry.pattern(
            for: nil,
            route: "65",
            directionName: "Westbound",
            in: [Self.pattern]
        )
        #expect(picked?.id == 4042)
    }
}
