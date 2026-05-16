import Foundation
import Testing
@testable import TransitModels

@Suite("ChoicePoint")
struct ChoicePointTests {
    @Test func codableRoundTripWithCoordinate() throws {
        let original = ChoicePoint(
            title: "Grand vs Chicago",
            location: PlannerCoordinate(latitude: 41.89, longitude: -87.63),
            decisionByTime: Date(timeIntervalSinceReferenceDate: 5_000),
            candidateIDs: [UUID(), UUID()],
            recommendedCandidateID: nil,
            recommendationReason: nil,
            hysteresisHoldUntil: Date(timeIntervalSinceReferenceDate: 5_300),
            confidence: 0.6
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChoicePoint.self, from: data)
        #expect(decoded == original)
    }

    @Test func confidenceClampedToUnitInterval() {
        let point = ChoicePoint(
            title: "X",
            candidateIDs: [UUID()],
            confidence: 2.0
        )
        #expect(point.confidence == 1)
    }

    @Test func nilLocationRoundTrips() throws {
        let original = ChoicePoint(
            title: "Walk or e-Divvy",
            candidateIDs: [UUID()],
            confidence: 0.5
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChoicePoint.self, from: data)
        #expect(decoded == original)
        #expect(decoded.location == nil)
    }
}
