import Foundation
import Testing
@testable import TransitModels

@Suite("LineHealthSnapshot")
struct LineHealthSnapshotTests {
    @Test func codableRoundTrip() throws {
        let original = LineHealthSnapshot(
            route: "Red",
            direction: "Howard",
            state: .longGap,
            confidence: 0.7,
            generatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            summary: "Long gap on Red Line."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LineHealthSnapshot.self, from: data)
        #expect(decoded == original)
    }

    @Test func confidenceClampedToUnitInterval() {
        let high = LineHealthSnapshot(
            route: "Blue", state: .normal, confidence: 2.0, generatedAt: .distantPast
        )
        let low = LineHealthSnapshot(
            route: "Blue", state: .normal, confidence: -1.0, generatedAt: .distantPast
        )
        #expect(high.confidence == 1)
        #expect(low.confidence == 0)
    }

    @Test func everyStateHasStableRawValue() throws {
        let data = try JSONEncoder().encode(LineHealthState.allCases)
        let decoded = try JSONDecoder().decode([LineHealthState].self, from: data)
        #expect(decoded == LineHealthState.allCases)
    }
}
