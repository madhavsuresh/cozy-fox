import Foundation
import Testing
@testable import TransitModels

@Suite("ActiveTripSession")
struct ActiveTripSessionTests {
    @Test func codableRoundTrip() throws {
        let optA = UUID()
        let optB = UUID()
        let session = ActiveTripSession(
            destinationTitle: "Work",
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            phase: .walkingToFirstLeg,
            candidateOptionIDs: [optA, optB],
            optionBeliefs: [optA: 0.7, optB: 0.3],
            inferredOptionID: optA,
            pendingChoicePointIDs: [],
            currentRecommendationOptionID: optA,
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_100)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ActiveTripSession.self, from: data)
        #expect(decoded == session)
    }

    @Test func normalizedBeliefsSumToOne() {
        let optA = UUID()
        let optB = UUID()
        let session = ActiveTripSession(
            destinationTitle: "Work",
            startedAt: .distantPast,
            candidateOptionIDs: [optA, optB],
            optionBeliefs: [optA: 2.0, optB: 6.0],
            lastUpdatedAt: .distantPast
        )
        let beliefs = session.normalizedBeliefs()
        let total = beliefs.values.reduce(0, +)
        #expect(abs(total - 1.0) < 0.001)
        #expect(abs(beliefs[optA]! - 0.25) < 0.001)
        #expect(abs(beliefs[optB]! - 0.75) < 0.001)
    }

    @Test func uniformBeliefsWhenInputIsAllZeros() {
        let optA = UUID()
        let optB = UUID()
        let session = ActiveTripSession(
            destinationTitle: "Work",
            startedAt: .distantPast,
            candidateOptionIDs: [optA, optB],
            optionBeliefs: [:],
            lastUpdatedAt: .distantPast
        )
        let beliefs = session.normalizedBeliefs()
        #expect(beliefs[optA] == 0.5)
        #expect(beliefs[optB] == 0.5)
    }
}
