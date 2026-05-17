import Foundation

/// How aggressively the dashboard hides train arrivals based on the
/// `TrainReliabilityScorer`'s verdict. User-facing knob (Settings →
/// Train predictions) over the existing reliability taxonomy — the
/// scorer's output is unchanged, only the cutoff between "show" and
/// "hide" moves. Mirrors `BusPredictionFilterLevel` so the two modes
/// share a mental model.
///
/// `inclusive` is the default and matches the behavior shipped before
/// the filter setting existed: everything except `doNotDisplay`
/// renders. The other levels exist for curiosity and debugging — see
/// `TrainPredictionFilter.filter` for the predicate each level applies.
public enum TrainPredictionFilterLevel: String, Codable, Sendable, CaseIterable, Hashable {
    /// Show only `highConfidence` rows. Everything else is dropped
    /// before the UI sees it.
    case conservative
    /// Show `highConfidence` and `mediumConfidence`. Drops low /
    /// unreliable / doNotDisplay.
    case balanced
    /// Show everything except `doNotDisplay`. Default — preserves the
    /// pre-setting behavior.
    case inclusive
    /// Show every arrival, including the rows the scorer wants to
    /// hide. `doNotDisplay` rows render with the `.cancelled`
    /// complication (red X) so the rider can see what was filtered.
    case showAll

    public static let `default`: TrainPredictionFilterLevel = .inclusive

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
            "Show only the arrivals Cozy Fox is most confident about."
        case .balanced:
            "Show confident arrivals; hide weak ones."
        case .inclusive:
            "Show all arrivals except ones we think are positively wrong."
        case .showAll:
            "Show every arrival. Likely-wrong rows are marked with an X."
        }
    }
}
