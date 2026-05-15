import Foundation

/// The hysteresis-approved recommendation for a portfolio at a given
/// tick. Distinct from `PortfolioEvaluation.recommendedOptionID` — that
/// field is the per-tick argmax candidate; this struct is what the
/// hysteresis state machine actually surfaces, with `changedAt`
/// reflecting the last approved transition rather than the candidate's
/// instantaneous identity.
public struct PortfolioRecommendation: Sendable, Hashable {
    public let optionID: UUID
    public let missCost: MissCostResult?
    /// When the recommendation last changed (per hysteresis). Equal
    /// to "now" on the tick the change happened; stable across ticks
    /// while the same option holds the recommendation.
    public let changedAt: Date
    /// `true` when the approved option's evaluation had
    /// `confidence < 1` — typically because walk time to the boarding
    /// stop was unknown. The dashboard mutes the miss-cost line in
    /// this case.
    public let lowConfidence: Bool

    public init(
        optionID: UUID,
        missCost: MissCostResult?,
        changedAt: Date,
        lowConfidence: Bool
    ) {
        self.optionID = optionID
        self.missCost = missCost
        self.changedAt = changedAt
        self.lowConfidence = lowConfidence
    }
}
