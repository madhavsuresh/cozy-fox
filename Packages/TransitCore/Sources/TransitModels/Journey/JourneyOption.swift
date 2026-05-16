import Foundation

public enum JourneySlot: Sendable, Hashable, Codable {
    case fixed(LegCandidate)
    case exchangeable(alternatives: [LegCandidate], policyHint: String?)

    public var candidates: [LegCandidate] {
        switch self {
        case .fixed(let leg): return [leg]
        case .exchangeable(let alternatives, _): return alternatives
        }
    }
}

public struct JourneyOption: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let title: String
    public let summary: String
    public let slots: [JourneySlot]
    public let tradeoffLabel: String?

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        slots: [JourneySlot],
        tradeoffLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.slots = slots
        self.tradeoffLabel = tradeoffLabel
    }
}
