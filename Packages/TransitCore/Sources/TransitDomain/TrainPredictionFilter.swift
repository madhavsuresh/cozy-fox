import Foundation
import TransitModels

/// Pure filter applied after the train reliability scorer runs but
/// before the UI sees the arrival list. Mirror of `BusPredictionFilter`.
///
/// Arrivals without a matching reliability assessment always pass
/// through — an unscored row means "we didn't have enough context to
/// rate this," not "we know it's bad."
public enum TrainPredictionFilter {
    public static func filter(
        _ arrivals: [Arrival],
        reliabilities: [String: TrainArrivalReliability],
        level: TrainPredictionFilterLevel
    ) -> [Arrival] {
        arrivals.filter { arrival in
            guard let assessment = reliabilities[arrival.id] else { return true }
            return shouldShow(state: assessment.state, level: level)
        }
    }

    /// Predicate for a single state at a given filter level. Public so
    /// callers that need to ask "should I render this row?" without
    /// going through the whole list can reuse it.
    public static func shouldShow(
        state: TrainArrivalReliability.State,
        level: TrainPredictionFilterLevel
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
