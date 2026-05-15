import Foundation
import TransitModels

/// Per-tick output of `PortfolioEvaluator.evaluate(...)`. Holds the
/// `RouteEvaluation` for every option in the portfolio plus the
/// per-option aggregate score and the argmax candidate. The hysteresis
/// state machine consumes this and may approve a recommendation that
/// differs from `recommendedOptionID` when the candidate just appeared
/// and hasn't beaten the current pick for long enough.
public struct PortfolioEvaluation: Sendable, Hashable {
    public let portfolioID: UUID
    public let evaluatedAt: Date
    public let evaluations: [RouteEvaluation]
    /// Aggregate ranking score per option, in weighted seconds. Lower
    /// is better. `.greatestFiniteMagnitude` for unavailable options.
    public let scores: [UUID: Double]
    /// The argmax — option with the lowest score among `available`
    /// options. `nil` when every option is unavailable.
    public let recommendedOptionID: UUID?

    public init(
        portfolioID: UUID,
        evaluatedAt: Date,
        evaluations: [RouteEvaluation],
        scores: [UUID: Double],
        recommendedOptionID: UUID?
    ) {
        self.portfolioID = portfolioID
        self.evaluatedAt = evaluatedAt
        self.evaluations = evaluations
        self.scores = scores
        self.recommendedOptionID = recommendedOptionID
    }

    public func evaluation(for optionID: UUID) -> RouteEvaluation? {
        evaluations.first { $0.optionID == optionID }
    }
}

/// Evaluates every option in a portfolio against a `PortfolioSnapshot`,
/// scores them, and picks the per-tick argmax. Pure / `Sendable`.
///
/// The evaluator deliberately does NOT compute miss cost — that's a
/// concern of the orchestrator, which decides which option to compute
/// miss cost FOR after the hysteresis state machine has had its say.
/// If the candidate differs from the hysteresis-approved option,
/// computing miss cost for the candidate would be wasted work.
public struct PortfolioEvaluator: Sendable {
    public let scorer: RouteOptionScorer

    public init(scorer: RouteOptionScorer = RouteOptionScorer()) {
        self.scorer = scorer
    }

    public func evaluate(
        portfolio: RoutePortfolio,
        snapshot: PortfolioSnapshot
    ) -> PortfolioEvaluation {
        let scored: [(eval: RouteEvaluation, score: Double)] = portfolio.options.map { option in
            let eval = scorer.evaluate(option: option, snapshot: snapshot)
            return (eval, scorer.score(eval, now: snapshot.now))
        }
        let scores = Dictionary(uniqueKeysWithValues: scored.map { ($0.eval.optionID, $0.score) })
        let recommendedID = scored
            .filter { $0.eval.available }
            .min { $0.score < $1.score }?
            .eval.optionID
        return PortfolioEvaluation(
            portfolioID: portfolio.id,
            evaluatedAt: snapshot.now,
            evaluations: scored.map(\.eval),
            scores: scores,
            recommendedOptionID: recommendedID
        )
    }
}
