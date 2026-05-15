import Foundation
import Testing
@testable import TransitDomain

@Suite("PortfolioHysteresis state machine")
struct PortfolioHysteresisTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 770_000_000)

    private func tick(_ minutesFromNow: Double) -> Date {
        Self.now.addingTimeInterval(minutesFromNow * 60)
    }

    /// Build a deterministic `PortfolioEvaluation` with chosen scores
    /// for two options. `available` defaults true for both.
    private func evaluation(
        portfolioID: UUID = UUID(),
        candidateID: UUID?,
        scoresByID: [UUID: Double],
        availabilityByID: [UUID: Bool]? = nil,
        evaluatedAt: Date = now
    ) -> PortfolioEvaluation {
        let evaluations: [RouteEvaluation] = scoresByID.map { id, _ in
            let available = availabilityByID?[id] ?? true
            return RouteEvaluation(
                optionID: id,
                available: available,
                etaMedian: evaluatedAt,
                etaStdDev: 0,
                pFailure: available ? 0 : 1,
                transferCount: 0,
                nextActionDeadline: evaluatedAt,
                confidence: available ? 1 : 0,
                imminentVehicle: nil,
                unavailableReason: available ? nil : .noArrivalsInHorizon
            )
        }
        return PortfolioEvaluation(
            portfolioID: portfolioID,
            evaluatedAt: evaluatedAt,
            evaluations: evaluations,
            scores: scoresByID,
            recommendedOptionID: candidateID
        )
    }

    // MARK: - Bootstrap

    @Test func bootstrap_adopts_first_candidate() {
        let h = PortfolioHysteresis()
        let optA = UUID()
        let outcome = h.step(
            state: .initial,
            evaluation: evaluation(candidateID: optA, scoresByID: [optA: 600]),
            now: Self.now
        )
        #expect(outcome.didChange == true)
        #expect(outcome.recommendedID == optA)
        #expect(outcome.state.currentRecommendedID == optA)
        #expect(outcome.state.lastChangedAt == Self.now)
    }

    @Test func bootstrap_with_no_candidate_changes_nothing() {
        let h = PortfolioHysteresis()
        let outcome = h.step(
            state: .initial,
            evaluation: evaluation(candidateID: nil, scoresByID: [:]),
            now: Self.now
        )
        #expect(outcome.didChange == false)
        #expect(outcome.recommendedID == nil)
        #expect(outcome.state.currentRecommendedID == nil)
    }

    // MARK: - Same candidate

    @Test func same_candidate_resets_pending_and_keeps_state() {
        let h = PortfolioHysteresis()
        let optA = UUID()
        let optB = UUID()
        // Pretend we had a pending B from a previous tick.
        let state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            pendingCandidateID: optB,
            consecutiveTicks: 1,
            lastChangedAt: Self.now
        )
        // This tick the candidate is back to A.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optA,
                scoresByID: [optA: 600, optB: 700]
            ),
            now: tick(0.5)
        )
        #expect(outcome.didChange == false)
        #expect(outcome.recommendedID == optA)
        #expect(outcome.state.pendingCandidateID == nil)
        #expect(outcome.state.consecutiveTicks == 0)
        #expect(outcome.state.lastChangedAt == Self.now)
    }

    // MARK: - Threshold gating

    @Test func candidate_with_small_delta_does_not_switch() {
        let h = PortfolioHysteresis(switchThresholdSeconds: 180, consecutiveTicksRequired: 2)
        let optA = UUID()
        let optB = UUID()
        let state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            lastChangedAt: Self.now
        )
        // Candidate beats A by only 60 s → below 180 s threshold.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optB,
                scoresByID: [optA: 600, optB: 540]
            ),
            now: tick(0.5)
        )
        #expect(outcome.didChange == false)
        #expect(outcome.recommendedID == optA)
        // Pending should NOT accumulate when delta is below threshold —
        // gating per-tick, no slow-burn switches across many small
        // improvements.
        #expect(outcome.state.pendingCandidateID == nil)
        #expect(outcome.state.consecutiveTicks == 0)
    }

    @Test func candidate_above_threshold_starts_counting_but_doesnt_switch_immediately() {
        let h = PortfolioHysteresis(switchThresholdSeconds: 180, consecutiveTicksRequired: 2)
        let optA = UUID()
        let optB = UUID()
        let state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            lastChangedAt: Self.now
        )
        // Delta = 300 s ≥ 180 → above threshold, but only first tick.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optB,
                scoresByID: [optA: 600, optB: 300]
            ),
            now: tick(0.5)
        )
        #expect(outcome.didChange == false)
        #expect(outcome.recommendedID == optA)
        #expect(outcome.state.pendingCandidateID == optB)
        #expect(outcome.state.consecutiveTicks == 1)
    }

    @Test func candidate_persists_for_required_ticks_then_switches() {
        let h = PortfolioHysteresis(switchThresholdSeconds: 180, consecutiveTicksRequired: 2)
        let optA = UUID()
        let optB = UUID()
        var state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            lastChangedAt: Self.now
        )

        // Tick 1: B takes the lead, accumulates to 1.
        let t1 = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optB,
                scoresByID: [optA: 600, optB: 300]
            ),
            now: tick(0.5)
        )
        #expect(t1.didChange == false)
        state = t1.state

        // Tick 2: B still beats; consecutiveTicks = 2 → switch.
        let t2 = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optB,
                scoresByID: [optA: 600, optB: 300]
            ),
            now: tick(1.0)
        )
        #expect(t2.didChange == true)
        #expect(t2.recommendedID == optB)
        #expect(t2.state.currentRecommendedID == optB)
        #expect(t2.state.pendingCandidateID == nil)
        #expect(t2.state.consecutiveTicks == 0)
        #expect(t2.state.lastChangedAt == tick(1.0))
    }

    @Test func pending_candidate_resets_when_a_new_candidate_appears() {
        let h = PortfolioHysteresis(switchThresholdSeconds: 180, consecutiveTicksRequired: 3)
        let optA = UUID()
        let optB = UUID()
        let optC = UUID()
        var state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            pendingCandidateID: optB,
            consecutiveTicks: 2,
            lastChangedAt: Self.now
        )

        // Tick: a different candidate (C) now leads. The pending B
        // count resets and C starts at 1.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optC,
                scoresByID: [optA: 600, optB: 580, optC: 200]
            ),
            now: tick(0.5)
        )
        state = outcome.state
        #expect(outcome.didChange == false)
        #expect(state.pendingCandidateID == optC)
        #expect(state.consecutiveTicks == 1)
    }

    // MARK: - Unavailability paths

    @Test func current_unavailable_switches_immediately() {
        let h = PortfolioHysteresis(switchThresholdSeconds: 180, consecutiveTicksRequired: 5)
        let optA = UUID()
        let optB = UUID()
        let state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            lastChangedAt: Self.now
        )
        // A is unavailable in this tick; B is the candidate. Switch
        // immediately even with a high persistence requirement.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: optB,
                scoresByID: [optA: .greatestFiniteMagnitude, optB: 300],
                availabilityByID: [optA: false, optB: true]
            ),
            now: tick(0.5)
        )
        #expect(outcome.didChange == true)
        #expect(outcome.recommendedID == optB)
        #expect(outcome.state.lastChangedAt == tick(0.5))
    }

    @Test func current_removed_from_portfolio_switches_immediately() {
        let h = PortfolioHysteresis(consecutiveTicksRequired: 5)
        let oldA = UUID()
        let newB = UUID()
        // State references option A, but the new evaluation only
        // contains B (user deleted A).
        let state = PortfolioHysteresis.State(
            currentRecommendedID: oldA,
            lastChangedAt: Self.now
        )
        let outcome = h.step(
            state: state,
            evaluation: evaluation(candidateID: newB, scoresByID: [newB: 600]),
            now: tick(0.5)
        )
        #expect(outcome.didChange == true)
        #expect(outcome.recommendedID == newB)
        #expect(outcome.state.currentRecommendedID == newB)
    }

    @Test func no_candidate_keeps_current() {
        let h = PortfolioHysteresis()
        let optA = UUID()
        let state = PortfolioHysteresis.State(
            currentRecommendedID: optA,
            lastChangedAt: Self.now
        )
        // Every option unavailable → no candidate.
        let outcome = h.step(
            state: state,
            evaluation: evaluation(
                candidateID: nil,
                scoresByID: [optA: .greatestFiniteMagnitude],
                availabilityByID: [optA: true]
            ),
            now: tick(0.5)
        )
        // A is still available in the evaluation; the recommended
        // argmax is nil because… well, candidateID is nil. Hysteresis
        // keeps current.
        #expect(outcome.didChange == false)
        #expect(outcome.recommendedID == optA)
    }
}
