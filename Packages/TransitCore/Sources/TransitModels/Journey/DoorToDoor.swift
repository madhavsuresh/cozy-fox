import Foundation

public struct DoorToDoorRequest: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let requestedAt: Date
    public let origin: JourneyPoint
    public let destination: JourneyPoint
    public let policyHint: String?
    public let hardDeadline: Date?

    public init(
        id: UUID = UUID(),
        requestedAt: Date,
        origin: JourneyPoint,
        destination: JourneyPoint,
        policyHint: String? = nil,
        hardDeadline: Date? = nil
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.origin = origin
        self.destination = destination
        self.policyHint = policyHint
        self.hardDeadline = hardDeadline
    }
}

public struct DoorToDoorPrediction: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let computedAt: Date
    public let bestOption: JourneyOption?
    public let alternatives: [JourneyOption]
    public let pendingChoicePoints: [ChoicePoint]
    public let explanationSummary: String?
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        computedAt: Date,
        bestOption: JourneyOption?,
        alternatives: [JourneyOption],
        pendingChoicePoints: [ChoicePoint],
        explanationSummary: String? = nil,
        confidence: Double
    ) {
        self.id = id
        self.requestID = requestID
        self.computedAt = computedAt
        self.bestOption = bestOption
        self.alternatives = alternatives
        self.pendingChoicePoints = pendingChoicePoints
        self.explanationSummary = explanationSummary
        self.confidence = max(0, min(1, confidence))
    }
}
