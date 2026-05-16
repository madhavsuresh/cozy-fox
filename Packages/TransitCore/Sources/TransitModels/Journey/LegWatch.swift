import Foundation

public enum LegWatchPriority: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case p0 = 0
    case p1 = 1
    case p2 = 2
    case p3 = 3
    case p4 = 4

    public static func < (lhs: LegWatchPriority, rhs: LegWatchPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LegRefreshPolicy: Sendable, Hashable, Codable {
    public let minIntervalSeconds: TimeInterval
    public let maxIntervalSeconds: TimeInterval
    public let volatilityMultiplier: Double

    public init(
        minIntervalSeconds: TimeInterval,
        maxIntervalSeconds: TimeInterval,
        volatilityMultiplier: Double = 1.0
    ) {
        self.minIntervalSeconds = max(0, minIntervalSeconds)
        self.maxIntervalSeconds = max(self.minIntervalSeconds, maxIntervalSeconds)
        self.volatilityMultiplier = max(0, volatilityMultiplier)
    }

    public static let p0 = LegRefreshPolicy(minIntervalSeconds: 15, maxIntervalSeconds: 60)
    public static let p1 = LegRefreshPolicy(minIntervalSeconds: 30, maxIntervalSeconds: 120)
    public static let p2 = LegRefreshPolicy(minIntervalSeconds: 60, maxIntervalSeconds: 240)
    public static let p3 = LegRefreshPolicy(minIntervalSeconds: 180, maxIntervalSeconds: 600)
    public static let p4 = LegRefreshPolicy(minIntervalSeconds: 600, maxIntervalSeconds: 1800)

    public static func `default`(for priority: LegWatchPriority) -> LegRefreshPolicy {
        switch priority {
        case .p0: .p0
        case .p1: .p1
        case .p2: .p2
        case .p3: .p3
        case .p4: .p4
        }
    }
}

public struct LegWatch: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let optionID: UUID
    public let slotIndex: Int
    public let role: String
    public let priority: LegWatchPriority
    public let policy: LegRefreshPolicy
    public let lastUpdatedAt: Date?
    public let affectedOptionIDs: [UUID]

    public init(
        id: UUID = UUID(),
        optionID: UUID,
        slotIndex: Int,
        role: String,
        priority: LegWatchPriority,
        policy: LegRefreshPolicy? = nil,
        lastUpdatedAt: Date? = nil,
        affectedOptionIDs: [UUID] = []
    ) {
        self.id = id
        self.optionID = optionID
        self.slotIndex = slotIndex
        self.role = role
        self.priority = priority
        self.policy = policy ?? LegRefreshPolicy.default(for: priority)
        self.lastUpdatedAt = lastUpdatedAt
        self.affectedOptionIDs = affectedOptionIDs
    }
}
