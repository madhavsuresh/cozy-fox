import Foundation
import Testing
@testable import TransitModels

@Suite("LegCandidate")
struct LegCandidateTests {
    @Test func allModesCovered() {
        let modes = Set(LegMode.allCases)
        let expected: Set<LegMode> = [
            .walk, .ctaBus, .ctaTrain, .metra, .intercampus,
            .divvyClassic, .divvyEBike, .freeBikeParking, .finalMile
        ]
        #expect(modes == expected)
    }

    @Test func codableRoundTrip() throws {
        let leg = LegCandidate(
            mode: .ctaTrain,
            displayLabel: "Red Line — Belmont",
            routeHint: "Red",
            fromPoint: .anchor(.home),
            toPoint: .station(systemRef: "40360", name: "Belmont", lineHint: "Red")
        )
        let data = try JSONEncoder().encode(leg)
        let decoded = try JSONDecoder().decode(LegCandidate.self, from: data)
        #expect(decoded == leg)
    }

    @Test func legModeRawValueStableAcrossEncoding() throws {
        let modes: [LegMode] = LegMode.allCases
        let data = try JSONEncoder().encode(modes)
        let decoded = try JSONDecoder().decode([LegMode].self, from: data)
        #expect(decoded == modes)
    }
}
