import Foundation
import TransitModels

public struct RankedJourney: Sendable, Hashable, Identifiable {
    public let option: JourneyOption
    public let distribution: JourneyDistribution
    public let tradeoffLabel: String?

    public var id: UUID { option.id }

    public init(option: JourneyOption, distribution: JourneyDistribution, tradeoffLabel: String? = nil) {
        self.option = option
        self.distribution = distribution
        self.tradeoffLabel = tradeoffLabel
    }
}

public protocol PolicyRanker: Sendable {
    func rank(_ inputs: [(option: JourneyOption, distribution: JourneyDistribution)]) -> [RankedJourney]
}

/// Default for veteran riders: lowest p80 unless another option's p50 is much
/// better. The improvement threshold is configurable. Used as the substrate
/// default per the architecture brief.
public struct LowestP80Ranker: PolicyRanker {
    public let p50ImprovementThresholdSeconds: TimeInterval

    public init(p50ImprovementThresholdSeconds: TimeInterval = 5 * 60) {
        self.p50ImprovementThresholdSeconds = max(0, p50ImprovementThresholdSeconds)
    }

    public func rank(_ inputs: [(option: JourneyOption, distribution: JourneyDistribution)]) -> [RankedJourney] {
        let withScores = inputs.map { input -> (input: (option: JourneyOption, distribution: JourneyDistribution), score: TimeInterval) in
            let p80 = input.distribution.totalDuration.p80
            return (input, p80)
        }
        let sorted = withScores.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.input.distribution.totalDuration.p50 < rhs.input.distribution.totalDuration.p50
            }
            return lhs.score < rhs.score
        }
        guard let best = sorted.first else { return [] }

        var promoted = best
        for candidate in sorted.dropFirst() {
            let p50Saving = promoted.input.distribution.totalDuration.p50 - candidate.input.distribution.totalDuration.p50
            if p50Saving > p50ImprovementThresholdSeconds {
                promoted = candidate
                break
            }
        }

        return sorted.map { entry in
            let label: String?
            if entry.input.option.id == promoted.input.option.id {
                label = entry.input.option.id == best.input.option.id ? "best realistic" : "fastest if it hits"
            } else if entry.input.option.id == best.input.option.id {
                label = "lowest p80"
            } else {
                label = entry.input.distribution.failureProbability > 0.2 ? "high miss cost" : nil
            }
            return RankedJourney(
                option: entry.input.option,
                distribution: entry.input.distribution,
                tradeoffLabel: label
            )
        }
    }
}

public struct FastestMedianRanker: PolicyRanker {
    public init() {}

    public func rank(_ inputs: [(option: JourneyOption, distribution: JourneyDistribution)]) -> [RankedJourney] {
        inputs
            .sorted { $0.distribution.totalDuration.p50 < $1.distribution.totalDuration.p50 }
            .map { RankedJourney(option: $0.option, distribution: $0.distribution, tradeoffLabel: nil) }
    }
}

public struct LowestP90Ranker: PolicyRanker {
    public init() {}

    public func rank(_ inputs: [(option: JourneyOption, distribution: JourneyDistribution)]) -> [RankedJourney] {
        inputs
            .sorted { $0.distribution.totalDuration.p90 < $1.distribution.totalDuration.p90 }
            .map { RankedJourney(option: $0.option, distribution: $0.distribution, tradeoffLabel: nil) }
    }
}

/// Hard-deadline policy: among options that catch with probability >= threshold,
/// pick the fastest p50. Used when a downstream deadline (Metra departure,
/// flight, meeting) dominates the decision.
public struct DeadlineSafeRanker: PolicyRanker {
    public let catchThreshold: Double
    public let deadlineAt: Date

    public init(catchThreshold: Double = 0.95, deadlineAt: Date) {
        self.catchThreshold = max(0, min(1, catchThreshold))
        self.deadlineAt = deadlineAt
    }

    public func rank(_ inputs: [(option: JourneyOption, distribution: JourneyDistribution)]) -> [RankedJourney] {
        let safe = inputs.filter { $0.distribution.failureProbability <= 1 - catchThreshold }
        let pool = safe.isEmpty ? inputs : safe
        return pool
            .sorted { $0.distribution.totalDuration.p50 < $1.distribution.totalDuration.p50 }
            .map { RankedJourney(option: $0.option, distribution: $0.distribution, tradeoffLabel: safe.isEmpty ? "no safe option" : nil) }
    }
}
