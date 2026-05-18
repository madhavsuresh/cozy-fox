import Foundation

/// One leg of a `DepartureLadderRow`'s door-to-door trip — e.g. walk to
/// the boarding stop, ride the train, walk the final mile. Means only;
/// the row's `arrivalAt` window still carries the spread.
public struct DepartureLadderLeg: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let mode: LegMode
    public let label: String
    public let meanSeconds: TimeInterval
    public let arrivalMean: Date

    public init(
        id: UUID = UUID(),
        mode: LegMode,
        label: String,
        meanSeconds: TimeInterval,
        arrivalMean: Date
    ) {
        self.id = id
        self.mode = mode
        self.label = label
        self.meanSeconds = max(0, meanSeconds)
        self.arrivalMean = arrivalMean
    }
}

public struct DepartureLadderRow: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let leaveByAt: Date
    public let totalDuration: TimeDistributionSummary
    public let arrivalAt: ArrivalWindow
    public let primaryLabel: String
    public let secondaryLabel: String?
    public let risk: WaitReasonableness
    public let note: String?
    public let catchProbability: Double
    public let missCostSeconds: TimeInterval?
    public let legs: [DepartureLadderLeg]

    public struct ArrivalWindow: Sendable, Hashable, Codable {
        public let low: Date
        public let high: Date

        public init(low: Date, high: Date) {
            if low <= high {
                self.low = low
                self.high = high
            } else {
                self.low = high
                self.high = low
            }
        }

        public var width: TimeInterval { high.timeIntervalSince(low) }
    }

    public init(
        id: UUID = UUID(),
        leaveByAt: Date,
        totalDuration: TimeDistributionSummary,
        arrivalAt: ArrivalWindow,
        primaryLabel: String,
        secondaryLabel: String? = nil,
        risk: WaitReasonableness,
        note: String? = nil,
        catchProbability: Double,
        missCostSeconds: TimeInterval? = nil,
        legs: [DepartureLadderLeg] = []
    ) {
        self.id = id
        self.leaveByAt = leaveByAt
        self.totalDuration = totalDuration
        self.arrivalAt = arrivalAt
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.risk = risk
        self.note = note
        self.catchProbability = max(0, min(1, catchProbability))
        self.missCostSeconds = missCostSeconds
        self.legs = legs
    }
}

public struct DepartureLadder: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let destinationTitle: String
    public let generatedAt: Date
    public let rows: [DepartureLadderRow]
    public let headline: String?
    public let nextCliffAt: Date?
    public let lineHealth: [LineHealthSnapshot]

    public init(
        id: UUID = UUID(),
        destinationTitle: String,
        generatedAt: Date,
        rows: [DepartureLadderRow],
        headline: String? = nil,
        nextCliffAt: Date? = nil,
        lineHealth: [LineHealthSnapshot] = []
    ) {
        self.id = id
        self.destinationTitle = destinationTitle
        self.generatedAt = generatedAt
        self.rows = rows
        self.headline = headline
        self.nextCliffAt = nextCliffAt
        self.lineHealth = lineHealth
    }

    public var sortedByLeaveBy: [DepartureLadderRow] {
        rows.sorted { $0.leaveByAt < $1.leaveByAt }
    }
}
