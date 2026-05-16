import Foundation
import TransitModels

public struct JourneySampleOutcome: Sendable, Hashable {
    public let totalDuration: TimeInterval
    public let didFail: Bool
    public let failureSlotIndex: Int?
    public let failureReason: String?

    public init(
        totalDuration: TimeInterval,
        didFail: Bool = false,
        failureSlotIndex: Int? = nil,
        failureReason: String? = nil
    ) {
        self.totalDuration = totalDuration
        self.didFail = didFail
        self.failureSlotIndex = failureSlotIndex
        self.failureReason = failureReason
    }
}

public struct JourneyDistribution: Sendable, Hashable {
    public let totalDuration: TimeDistributionSummary
    public let failureProbability: Double
    public let samples: Int
    public let dominantFailureReason: String?

    public init(
        totalDuration: TimeDistributionSummary,
        failureProbability: Double,
        samples: Int,
        dominantFailureReason: String? = nil
    ) {
        self.totalDuration = totalDuration
        self.failureProbability = max(0, min(1, failureProbability))
        self.samples = max(0, samples)
        self.dominantFailureReason = dominantFailureReason
    }
}

public struct JourneyComposer: Sendable {
    public init() {}

    public func sample<G: RandomNumberGenerator>(
        option: JourneyOption,
        legProcesses: [UUID: any PreparedLegProcess],
        startingAt: Date,
        rng: inout G
    ) -> JourneySampleOutcome {
        var totalDuration: TimeInterval = 0
        var currentTime = startingAt
        for (index, slot) in option.slots.enumerated() {
            let candidate = chooseCandidate(for: slot)
            guard let prepared = legProcesses[candidate.id] else {
                return JourneySampleOutcome(
                    totalDuration: totalDuration,
                    didFail: true,
                    failureSlotIndex: index,
                    failureReason: "Missing kernel for slot \(index)."
                )
            }
            let outcome = prepared.sample(startingAt: currentTime, rng: &rng)
            totalDuration += outcome.totalDuration
            currentTime = currentTime.addingTimeInterval(outcome.totalDuration)
            if outcome.didFail {
                return JourneySampleOutcome(
                    totalDuration: totalDuration,
                    didFail: true,
                    failureSlotIndex: index,
                    failureReason: outcome.failureReason
                )
            }
        }
        return JourneySampleOutcome(totalDuration: totalDuration)
    }

    public func compose<G: RandomNumberGenerator>(
        option: JourneyOption,
        legProcesses: [UUID: any PreparedLegProcess],
        startingAt: Date,
        samples: Int,
        rng: inout G
    ) -> JourneyDistribution {
        let n = max(1, samples)
        var durations: [TimeInterval] = []
        durations.reserveCapacity(n)
        var failures = 0
        var failureReasonCounts: [String: Int] = [:]

        for _ in 0..<n {
            let outcome = sample(option: option, legProcesses: legProcesses, startingAt: startingAt, rng: &rng)
            durations.append(outcome.totalDuration)
            if outcome.didFail {
                failures += 1
                if let reason = outcome.failureReason {
                    failureReasonCounts[reason, default: 0] += 1
                }
            }
        }

        let summary = TimeDistributionSummary.empirical(from: durations)
        let dominantReason = failureReasonCounts.max(by: { $0.value < $1.value })?.key
        return JourneyDistribution(
            totalDuration: summary,
            failureProbability: Double(failures) / Double(n),
            samples: n,
            dominantFailureReason: dominantReason
        )
    }

    private func chooseCandidate(for slot: JourneySlot) -> LegCandidate {
        switch slot {
        case .fixed(let leg):
            return leg
        case .exchangeable(let alternatives, _):
            return alternatives.first ?? LegCandidate(
                mode: .walk,
                displayLabel: "Missing",
                fromPoint: .anchor(.home),
                toPoint: .anchor(.work)
            )
        }
    }
}
