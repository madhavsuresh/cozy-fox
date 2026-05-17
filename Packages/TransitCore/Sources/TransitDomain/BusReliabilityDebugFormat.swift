import Foundation
import TransitModels

/// Compact one-line summary of a prediction's reliability for the
/// power-user debug overlay. Format:
///
///     "<eta>m  <state> <score>  <reasons>"
///
/// e.g. ` 3m  H 0.81  VEHICLE_FRESH,ROUTE_MATCH,PATTERN_MATCH`.
///
/// Pure function so unit tests can lock the format down — the overlay
/// is cosmetic but I want to notice when its shape changes.
public enum BusReliabilityDebugFormat {
    public static func line(
        for prediction: BusPrediction,
        reliability: BusArrivalReliability?,
        now: Date
    ) -> String {
        let mins = max(0, Int((prediction.arrivalAt.timeIntervalSince(now) / 60).rounded()))
        guard let reliability else {
            return String(format: "%2dm  unscored", mins)
        }
        let stateGlyph: String = {
            switch reliability.state {
            case .highConfidence:   "H"
            case .mediumConfidence: "M"
            case .lowConfidence:    "L"
            case .unreliable:       "U"
            case .doNotDisplay:     "X"
            }
        }()
        let reasons = reliability.reasonCodes
            .prefix(3)
            .map(\.rawValue)
            .joined(separator: ",")
        return String(
            format: "%2dm  %@ %.2f  %@",
            mins,
            stateGlyph,
            reliability.score,
            reasons
        )
    }
}
