import Foundation
import TransitModels

/// Pure filter applied after the reliability scorer runs but before the
/// UI sees the prediction list. Encapsulates the user-facing
/// `BusPredictionFilterLevel` semantics so the dashboard, detail
/// screen, live activity, and tests all agree on what each level means.
///
/// Predictions without a matching reliability assessment always pass
/// through — the caller is expected to have run the scorer over the
/// full set; an unscored row means "we didn't have enough context to
/// rate this," not "we know it's bad."
public enum BusPredictionFilter {
    public static func filter(
        _ predictions: [BusPrediction],
        reliabilities: [String: BusArrivalReliability],
        level: BusPredictionFilterLevel
    ) -> [BusPrediction] {
        predictions.filter { prediction in
            guard let assessment = reliabilities[prediction.id] else { return true }
            return shouldShow(state: assessment.state, level: level)
        }
    }

    /// Predicate for a single state at a given filter level. Public so
    /// callers that need to ask "should I render this row?" without
    /// going through the whole list (e.g. detail surfaces) can reuse
    /// it.
    public static func shouldShow(
        state: BusArrivalReliability.State,
        level: BusPredictionFilterLevel
    ) -> Bool {
        switch level {
        case .conservative:
            return state == .highConfidence
        case .balanced:
            return state == .highConfidence || state == .mediumConfidence
        case .inclusive:
            return state != .doNotDisplay
        case .showAll:
            return true
        }
    }
}
