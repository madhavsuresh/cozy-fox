import Foundation

public enum PredictionLogKind: String, Sendable, Hashable, Codable, CaseIterable {
    case request
    case frontier
    case recommendation
    case notification
    case choicePoint
    case lineHealth
    case inferredOption
    case actualOutcome
}

public struct PredictionLogEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let predictionID: UUID
    public let loggedAt: Date
    public let kind: PredictionLogKind
    public let optionID: UUID?
    public let payloadJSON: String

    public init(
        id: UUID = UUID(),
        predictionID: UUID,
        loggedAt: Date,
        kind: PredictionLogKind,
        optionID: UUID? = nil,
        payloadJSON: String
    ) {
        self.id = id
        self.predictionID = predictionID
        self.loggedAt = loggedAt
        self.kind = kind
        self.optionID = optionID
        self.payloadJSON = payloadJSON
    }
}

public struct JourneyEpisodeLog: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let startedAt: Date
    public let closedAt: Date?
    public let entries: [PredictionLogEntry]
    public let actualOutcomeJSON: String?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        startedAt: Date,
        closedAt: Date? = nil,
        entries: [PredictionLogEntry] = [],
        actualOutcomeJSON: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.closedAt = closedAt
        self.entries = entries
        self.actualOutcomeJSON = actualOutcomeJSON
    }

    public var isOpen: Bool { closedAt == nil }

    public func appending(_ entry: PredictionLogEntry) -> JourneyEpisodeLog {
        JourneyEpisodeLog(
            id: id,
            sessionID: sessionID,
            startedAt: startedAt,
            closedAt: closedAt,
            entries: entries + [entry],
            actualOutcomeJSON: actualOutcomeJSON
        )
    }

    public func closed(at date: Date, actualOutcomeJSON: String? = nil) -> JourneyEpisodeLog {
        JourneyEpisodeLog(
            id: id,
            sessionID: sessionID,
            startedAt: startedAt,
            closedAt: date,
            entries: entries,
            actualOutcomeJSON: actualOutcomeJSON ?? self.actualOutcomeJSON
        )
    }
}
