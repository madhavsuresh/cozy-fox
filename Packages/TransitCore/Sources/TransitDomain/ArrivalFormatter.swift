import Foundation
import TransitModels

public enum ArrivalLabel: Equatable, Sendable, Hashable {
    case due
    case approaching
    case minutes(Int)
    case delayed(Int)
    case scheduled(Int)

    public var shortText: String {
        switch self {
        case .due: "Due"
        case .approaching: "Now"
        case .minutes(let m): "\(m) min"
        case .delayed(let m): "\(m) min ⚠"
        case .scheduled(let m): "~\(m) min"
        }
    }
}

public enum ArrivalFormatter {
    public static func label(for arrival: Arrival, clock: Clock = SystemClock()) -> ArrivalLabel {
        let mins = arrival.minutesUntilArrival(now: clock.now)
        if arrival.isApproaching || mins <= 0 { return .approaching }
        if mins == 1 { return .due }
        if arrival.isDelayed { return .delayed(mins) }
        if arrival.isScheduled { return .scheduled(mins) }
        return .minutes(mins)
    }

    public static func label(for prediction: BusPrediction, clock: Clock = SystemClock()) -> ArrivalLabel {
        let mins = prediction.minutesUntilArrival(now: clock.now)
        if prediction.isApproaching || mins <= 0 { return .approaching }
        if mins == 1 { return .due }
        if prediction.isDelayed { return .delayed(mins) }
        return .minutes(mins)
    }
}
