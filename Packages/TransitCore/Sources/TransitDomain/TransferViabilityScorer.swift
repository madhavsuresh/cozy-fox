import Foundation

public struct TransferViabilityScore: Sendable, Hashable {
    public let score: Double
    public let transferCount: Int
    public let expectedTravelTime: TimeInterval

    public init(score: Double, transferCount: Int, expectedTravelTime: TimeInterval) {
        self.score = min(1, max(0, score))
        self.transferCount = transferCount
        self.expectedTravelTime = expectedTravelTime
    }
}

public struct TransferViabilityScorer: Sendable {
    public init() {}

    public func score(
        plan: TripPlan,
        firstLegOpportunity: TransitOpportunityScore? = nil
    ) -> TransferViabilityScore {
        let transitLegCount = plan.legs.filter { $0.mode == .transit }.count
        let transferCount = max(0, transitLegCount - 1)
        let walkingMeters = plan.legs
            .filter { $0.mode == .walking }
            .map(\.distanceMeters)
            .reduce(0, +)

        var score = 0.82
        score -= Double(transferCount) * 0.13
        score -= min(0.18, walkingMeters / 10_000)
        score -= min(0.18, plan.expectedTravelTime / (90 * 60) * 0.12)

        if let firstLegOpportunity {
            score = score * 0.65 + firstLegOpportunity.score * 0.35
            switch firstLegOpportunity.catchability {
            case .tooSoon, .past:
                score -= 0.35
            case .tight:
                score -= 0.08
            case .comfortable:
                score += 0.04
            case .distant, .unknown:
                break
            }
        }

        return TransferViabilityScore(
            score: score,
            transferCount: transferCount,
            expectedTravelTime: plan.expectedTravelTime
        )
    }
}
