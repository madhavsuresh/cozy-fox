import Foundation
import TransitModels

/// Compact one-line summary of a train arrival's reliability for the
/// power-user debug overlay. Mirror of `BusReliabilityDebugFormat`.
///
///     "<eta>m  <state> <score>  <reasons>"
///
/// e.g. ` 3m  H 0.81  VEHICLE_FRESH,LINE_MATCH,NEXT_STOP_MATCHES_ARRIVAL`.
public enum TrainReliabilityDebugFormat {
    public static func line(
        for arrival: Arrival,
        reliability: TrainArrivalReliability?,
        now: Date
    ) -> String {
        let mins = max(0, Int((arrival.arrivalAt.timeIntervalSince(now) / 60).rounded()))
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
