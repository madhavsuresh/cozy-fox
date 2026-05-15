import Foundation

/// Per-portfolio state machine that gates recommendation switches so
/// transient blips in the per-tick argmax don't flicker the dashboard
/// card. Pure / `Sendable` / value type — the caller (RefreshCoordinator)
/// owns the storage for `State` between ticks.
///
/// Switch rules, ANDed:
/// 1. The candidate beats the current recommendation by ≥
///    `switchThresholdSeconds` of aggregate score.
/// 2. The candidate has been the argmax for ≥ `consecutiveTicksRequired`
///    consecutive ticks (with the 30 s foreground ticker this is ~60 s
///    of observation by default).
///
/// Exception paths that switch immediately, bypassing the gates:
/// - First evaluation (no current recommendation yet).
/// - Current option is no longer in the portfolio (was removed).
/// - Current option's `RouteEvaluation` is unavailable (closed station,
///   no arrivals in horizon).
public struct PortfolioHysteresis: Sendable {
    public let switchThresholdSeconds: TimeInterval
    public let consecutiveTicksRequired: Int

    public init(
        switchThresholdSeconds: TimeInterval = 180,
        consecutiveTicksRequired: Int = 2
    ) {
        self.switchThresholdSeconds = switchThresholdSeconds
        self.consecutiveTicksRequired = consecutiveTicksRequired
    }

    public struct State: Sendable, Hashable {
        /// The option currently surfaced to the user. `nil` until the
        /// first evaluation lands.
        public var currentRecommendedID: UUID?
        /// The candidate that's been beating `current` recently but
        /// hasn't yet earned the switch. Reset whenever the candidate
        /// changes or stops being a candidate.
        public var pendingCandidateID: UUID?
        /// How many consecutive ticks `pendingCandidateID` has been
        /// the argmax with delta ≥ threshold.
        public var consecutiveTicks: Int
        /// When `currentRecommendedID` was last set to a new value.
        /// Used by the dashboard to render "as of" timestamps.
        public var lastChangedAt: Date?

        public init(
            currentRecommendedID: UUID? = nil,
            pendingCandidateID: UUID? = nil,
            consecutiveTicks: Int = 0,
            lastChangedAt: Date? = nil
        ) {
            self.currentRecommendedID = currentRecommendedID
            self.pendingCandidateID = pendingCandidateID
            self.consecutiveTicks = consecutiveTicks
            self.lastChangedAt = lastChangedAt
        }

        public static let initial = State()
    }

    public struct Outcome: Sendable, Hashable {
        public let state: State
        /// What the caller should surface. May equal
        /// `state.currentRecommendedID` (typical) or differ during
        /// the same tick when the state transitions.
        public let recommendedID: UUID?
        /// `true` when this tick changed the surfaced recommendation
        /// (`recommendedID != prior currentRecommendedID`).
        public let didChange: Bool

        public init(state: State, recommendedID: UUID?, didChange: Bool) {
            self.state = state
            self.recommendedID = recommendedID
            self.didChange = didChange
        }
    }

    public func step(
        state: State,
        evaluation: PortfolioEvaluation,
        now: Date
    ) -> Outcome {
        let candidateID = evaluation.recommendedOptionID

        // 1. Bootstrap — no current recommendation.
        guard let currentID = state.currentRecommendedID else {
            let next = State(
                currentRecommendedID: candidateID,
                pendingCandidateID: nil,
                consecutiveTicks: 0,
                lastChangedAt: candidateID != nil ? now : nil
            )
            return Outcome(state: next, recommendedID: candidateID, didChange: candidateID != nil)
        }

        // 2. Current is no longer in the portfolio (option removed).
        //    Switch to candidate immediately.
        let currentEval = evaluation.evaluation(for: currentID)
        if currentEval == nil {
            let next = State(
                currentRecommendedID: candidateID,
                pendingCandidateID: nil,
                consecutiveTicks: 0,
                lastChangedAt: candidateID != nil ? now : nil
            )
            return Outcome(
                state: next,
                recommendedID: candidateID,
                didChange: candidateID != currentID
            )
        }

        // 3. Current is unavailable (closed station, no arrivals in
        //    horizon, etc.). Switch to candidate immediately.
        if currentEval?.available == false {
            let next = State(
                currentRecommendedID: candidateID,
                pendingCandidateID: nil,
                consecutiveTicks: 0,
                lastChangedAt: candidateID != nil ? now : state.lastChangedAt
            )
            return Outcome(
                state: next,
                recommendedID: candidateID,
                didChange: candidateID != currentID
            )
        }

        // 4. No candidate (every option unavailable except current),
        //    or candidate == current. Keep current, reset pending.
        guard let candidateID, candidateID != currentID else {
            let next = State(
                currentRecommendedID: currentID,
                pendingCandidateID: nil,
                consecutiveTicks: 0,
                lastChangedAt: state.lastChangedAt
            )
            return Outcome(state: next, recommendedID: currentID, didChange: false)
        }

        // 5. Different candidate. Compute delta.
        let currentScore = evaluation.scores[currentID] ?? .greatestFiniteMagnitude
        let candidateScore = evaluation.scores[candidateID] ?? .greatestFiniteMagnitude
        let delta = currentScore - candidateScore  // positive ⇒ candidate is better
        guard delta >= switchThresholdSeconds else {
            // Improvement too small to act on; reset any pending count
            // for this candidate.
            let next = State(
                currentRecommendedID: currentID,
                pendingCandidateID: nil,
                consecutiveTicks: 0,
                lastChangedAt: state.lastChangedAt
            )
            return Outcome(state: next, recommendedID: currentID, didChange: false)
        }

        // 6. Improvement large enough. Check persistence.
        if state.pendingCandidateID == candidateID {
            let nextTicks = state.consecutiveTicks + 1
            if nextTicks >= consecutiveTicksRequired {
                let next = State(
                    currentRecommendedID: candidateID,
                    pendingCandidateID: nil,
                    consecutiveTicks: 0,
                    lastChangedAt: now
                )
                return Outcome(state: next, recommendedID: candidateID, didChange: true)
            }
            // Still pending, accumulate.
            let next = State(
                currentRecommendedID: currentID,
                pendingCandidateID: candidateID,
                consecutiveTicks: nextTicks,
                lastChangedAt: state.lastChangedAt
            )
            return Outcome(state: next, recommendedID: currentID, didChange: false)
        }

        // 7. New candidate took the lead this tick. Start counting.
        let next = State(
            currentRecommendedID: currentID,
            pendingCandidateID: candidateID,
            consecutiveTicks: 1,
            lastChangedAt: state.lastChangedAt
        )
        return Outcome(state: next, recommendedID: currentID, didChange: false)
    }
}
