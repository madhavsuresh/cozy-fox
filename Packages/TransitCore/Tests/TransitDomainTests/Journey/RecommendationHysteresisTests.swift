import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("RecommendationHysteresis")
struct RecommendationHysteresisTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func option(_ name: String) -> JourneyOption {
        JourneyOption(title: name, summary: name, slots: [])
    }

    private func ranked(_ entries: [(JourneyOption, p80: TimeInterval)]) -> [RankedJourney] {
        entries.map { (opt, p80) in
            RankedJourney(
                option: opt,
                distribution: JourneyDistribution(
                    totalDuration: TimeDistributionSummary(
                        mean: p80, p50: p80, p80: p80, p90: p80 + 60,
                        confidence: 0.7, sampleCount: 64
                    ),
                    failureProbability: 0,
                    samples: 64
                )
            )
        }
    }

    @Test func firstTickAdoptsTopRecommendation() {
        let hysteresis = RecommendationHysteresis()
        let optA = option("A")
        let next = hysteresis.step(
            state: HysteresisState(lastEvaluatedAt: Self.t0),
            ranked: ranked([(optA, p80: 1500)]),
            now: Self.t0
        )
        #expect(next.currentRecommendationID == optA.id)
        #expect(next.pendingRecommendationID == nil)
    }

    @Test func stableTopHoldsCurrentRecommendation() {
        let hysteresis = RecommendationHysteresis()
        let optA = option("A")
        var state = HysteresisState(currentRecommendationID: optA.id, lastEvaluatedAt: Self.t0)
        for offset in 1...4 {
            state = hysteresis.step(
                state: state,
                ranked: ranked([(optA, p80: 1500)]),
                now: Self.t0.addingTimeInterval(Double(offset) * 30)
            )
        }
        #expect(state.currentRecommendationID == optA.id)
    }

    @Test func smallGapDoesNotSwitch() {
        let hysteresis = RecommendationHysteresis(sustainSeconds: 30, p80GapThresholdSeconds: 90)
        let optA = option("A")
        let optB = option("B")
        var state = HysteresisState(currentRecommendationID: optA.id, lastEvaluatedAt: Self.t0)
        state = hysteresis.step(
            state: state,
            ranked: ranked([(optB, p80: 1500), (optA, p80: 1530)]),
            now: Self.t0.addingTimeInterval(60)
        )
        #expect(state.currentRecommendationID == optA.id)
        #expect(state.pendingRecommendationID == nil)
    }

    @Test func sustainedDominanceFlipsRecommendation() {
        let hysteresis = RecommendationHysteresis(sustainSeconds: 30, p80GapThresholdSeconds: 60)
        let optA = option("A")
        let optB = option("B")
        var state = HysteresisState(currentRecommendationID: optA.id, lastEvaluatedAt: Self.t0)
        state = hysteresis.step(
            state: state,
            ranked: ranked([(optB, p80: 1300), (optA, p80: 1500)]),
            now: Self.t0.addingTimeInterval(10)
        )
        #expect(state.pendingRecommendationID == optB.id)
        #expect(state.currentRecommendationID == optA.id)
        state = hysteresis.step(
            state: state,
            ranked: ranked([(optB, p80: 1300), (optA, p80: 1500)]),
            now: Self.t0.addingTimeInterval(50)
        )
        #expect(state.currentRecommendationID == optB.id)
        #expect(state.pendingRecommendationID == nil)
    }

    @Test func bypassImmediatelySwitches() {
        let hysteresis = RecommendationHysteresis(sustainSeconds: 30, p80GapThresholdSeconds: 60)
        let optA = option("A")
        let optB = option("B")
        let state = HysteresisState(currentRecommendationID: optA.id, lastEvaluatedAt: Self.t0)
        let next = hysteresis.step(
            state: state,
            ranked: ranked([(optB, p80: 2000), (optA, p80: 1500)]),
            now: Self.t0.addingTimeInterval(5),
            bypass: .lastGoodOption
        )
        #expect(next.currentRecommendationID == optB.id)
    }

    @Test func emptyRankingClearsRecommendation() {
        let hysteresis = RecommendationHysteresis()
        let optA = option("A")
        let state = HysteresisState(currentRecommendationID: optA.id, lastEvaluatedAt: Self.t0)
        let next = hysteresis.step(state: state, ranked: [], now: Self.t0.addingTimeInterval(60))
        #expect(next.currentRecommendationID == nil)
    }
}
