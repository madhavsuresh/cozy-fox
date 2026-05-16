import Foundation
import Testing
@testable import TransitModels

@Suite("DoorToDoor request and prediction")
struct DoorToDoorTests {
    @Test func requestCodableRoundTrip() throws {
        let original = DoorToDoorRequest(
            requestedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            origin: .anchor(.home),
            destination: .namedPlace(title: "Streeterville", subtitle: nil, latitude: 41.89, longitude: -87.61),
            policyHint: "lowest_p80",
            hardDeadline: Date(timeIntervalSinceReferenceDate: 5_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoorToDoorRequest.self, from: data)
        #expect(decoded == original)
    }

    @Test func predictionCodableRoundTripWithBestOption() throws {
        let leg = LegCandidate(
            mode: .ctaTrain,
            displayLabel: "Red Line",
            fromPoint: .anchor(.home),
            toPoint: .anchor(.work)
        )
        let best = JourneyOption(
            title: "Red Line",
            summary: "Red Line to Belmont",
            slots: [.fixed(leg)]
        )
        let original = DoorToDoorPrediction(
            requestID: UUID(),
            computedAt: Date(timeIntervalSinceReferenceDate: 1_500),
            bestOption: best,
            alternatives: [],
            pendingChoicePoints: [],
            explanationSummary: "Best realistic",
            confidence: 0.7
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoorToDoorPrediction.self, from: data)
        #expect(decoded == original)
    }

    @Test func predictionWithoutBestOptionRoundTrips() throws {
        let original = DoorToDoorPrediction(
            requestID: UUID(),
            computedAt: Date(timeIntervalSinceReferenceDate: 1_500),
            bestOption: nil,
            alternatives: [],
            pendingChoicePoints: [],
            confidence: 0.0
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoorToDoorPrediction.self, from: data)
        #expect(decoded == original)
    }
}
