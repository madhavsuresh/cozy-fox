import Foundation

public enum WaitReasonableness: String, Sendable, Hashable, Codable, CaseIterable {
    case goodWait
    case acceptableWait
    case riskyWait
    case badGap
    case bunched
    case feedUnreliable
    case unknown

    public var label: String {
        switch self {
        case .goodWait: "Comfortable wait"
        case .acceptableWait: "Fine to wait"
        case .riskyWait: "Cutting it close"
        case .badGap: "Long gap"
        case .bunched: "Bunched"
        case .feedUnreliable: "Feed unreliable"
        case .unknown: "Unknown"
        }
    }

    public var tone: ArrivalConfidenceMark.Tone {
        switch self {
        case .goodWait, .acceptableWait, .bunched: .strong
        case .riskyWait: .normal
        case .badGap, .feedUnreliable, .unknown: .weak
        }
    }
}
