import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("PolicyRanker")
struct PolicyRankerTests {
    private func option(_ title: String) -> JourneyOption {
        JourneyOption(title: title, summary: title, slots: [])
    }

    private func distribution(mean: TimeInterval, p50: TimeInterval, p80: TimeInterval, p90: TimeInterval, failure: Double = 0) -> JourneyDistribution {
        JourneyDistribution(
            totalDuration: TimeDistributionSummary(
                mean: mean, p50: p50, p80: p80, p90: p90, confidence: 0.7, sampleCount: 64
            ),
            failureProbability: failure,
            samples: 64
        )
    }

    @Test func lowestP80PicksLowestTail() {
        let ranker = LowestP80Ranker()
        let inputs = [
            (option: option("A"), distribution: distribution(mean: 1500, p50: 1500, p80: 2400, p90: 2700)),
            (option: option("B"), distribution: distribution(mean: 1700, p50: 1700, p80: 2100, p90: 2300))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.first?.option.title == "B")
        #expect(ranked.first?.tradeoffLabel == "best realistic")
    }

    @Test func lowestP80PromotesFasterMedianWhenSavingExceedsThreshold() {
        let ranker = LowestP80Ranker(p50ImprovementThresholdSeconds: 5 * 60)
        let inputs = [
            (option: option("safe"), distribution: distribution(mean: 2400, p50: 2400, p80: 2500, p90: 2600)),
            (option: option("fast"), distribution: distribution(mean: 1500, p50: 1500, p80: 2700, p90: 3000))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.contains(where: { $0.option.title == "fast" && $0.tradeoffLabel == "fastest if it hits" }))
        #expect(ranked.contains(where: { $0.option.title == "safe" && $0.tradeoffLabel == "lowest p80" }))
    }

    @Test func fastestMedianSortsByP50() {
        let ranker = FastestMedianRanker()
        let inputs = [
            (option: option("slow"), distribution: distribution(mean: 1800, p50: 1800, p80: 2000, p90: 2100)),
            (option: option("fast"), distribution: distribution(mean: 1200, p50: 1200, p80: 1800, p90: 2400))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.first?.option.title == "fast")
    }

    @Test func lowestP90PicksWidestSafetyMargin() {
        let ranker = LowestP90Ranker()
        let inputs = [
            (option: option("A"), distribution: distribution(mean: 1500, p50: 1500, p80: 1800, p90: 2700)),
            (option: option("B"), distribution: distribution(mean: 1700, p50: 1700, p80: 2000, p90: 2200))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.first?.option.title == "B")
    }

    @Test func deadlineSafeFiltersByCatchProbability() {
        let ranker = DeadlineSafeRanker(catchThreshold: 0.95, deadlineAt: .distantFuture)
        let inputs = [
            (option: option("risky-fast"), distribution: distribution(mean: 1200, p50: 1200, p80: 1500, p90: 1800, failure: 0.4)),
            (option: option("safe-slow"), distribution: distribution(mean: 1600, p50: 1600, p80: 1700, p90: 1800, failure: 0.02))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.first?.option.title == "safe-slow")
    }

    @Test func deadlineSafeFallsBackWhenNoOptionSafe() {
        let ranker = DeadlineSafeRanker(catchThreshold: 0.95, deadlineAt: .distantFuture)
        let inputs = [
            (option: option("A"), distribution: distribution(mean: 1200, p50: 1200, p80: 1500, p90: 1800, failure: 0.4)),
            (option: option("B"), distribution: distribution(mean: 1600, p50: 1600, p80: 1700, p90: 1800, failure: 0.3))
        ]
        let ranked = ranker.rank(inputs)
        #expect(ranked.first?.tradeoffLabel == "no safe option")
    }
}
