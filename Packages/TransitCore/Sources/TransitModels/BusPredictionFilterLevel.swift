import Foundation

/// How aggressively the dashboard hides bus predictions based on the
/// `BusReliabilityScorer`'s verdict. A user-facing knob (Settings →
/// Bus predictions) over the existing reliability taxonomy — the
/// scorer's output is unchanged, only the cutoff between "show" and
/// "hide" moves.
///
/// `inclusive` is the default and matches the behavior shipped before
/// the filter setting existed: everything except `doNotDisplay`
/// renders. The other levels exist for curiosity and debugging — see
/// `BusPredictionFilter.filter` for the predicate each level applies.
public enum BusPredictionFilterLevel: String, Codable, Sendable, CaseIterable, Hashable {
    /// Show only `highConfidence` rows. Everything else is dropped
    /// before the UI sees it.
    case conservative
    /// Show `highConfidence` and `mediumConfidence`. Drops low /
    /// unreliable / doNotDisplay.
    case balanced
    /// Show everything except `doNotDisplay`. Default — preserves the
    /// pre-setting behavior.
    case inclusive
    /// Show every prediction, including the rows the scorer wants to
    /// hide. `doNotDisplay` rows render with the `.cancelled`
    /// complication (red X) so the rider can see what was filtered.
    case showAll

    public static let `default`: BusPredictionFilterLevel = .inclusive

    /// Stable, user-readable label for settings UI.
    public var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced:     "Balanced"
        case .inclusive:    "Inclusive"
        case .showAll:      "Show everything"
        }
    }

    /// One-sentence description for the settings footer.
    public var summary: String {
        switch self {
        case .conservative:
            "Show only the predictions Cozy Fox is most confident about."
        case .balanced:
            "Show confident predictions; hide weak ones."
        case .inclusive:
            "Show all predictions except ones we think are positively wrong."
        case .showAll:
            "Show every prediction. Likely-wrong rows are marked with an X."
        }
    }
}
