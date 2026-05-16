import Foundation

public enum ActiveTripPhase: String, Sendable, Hashable, Codable, CaseIterable {
    case notStarted
    case walkingToFirstLeg
    case waitingForVehicle
    case inTransit
    case atChoicePoint
    case finalMile
    case arrived
}

public struct ActiveTripSession: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let destinationTitle: String
    public let startedAt: Date
    public let phase: ActiveTripPhase
    public let candidateOptionIDs: [UUID]
    public let optionBeliefs: [UUID: Double]
    public let inferredOptionID: UUID?
    public let pendingChoicePointIDs: [UUID]
    public let currentRecommendationOptionID: UUID?
    public let lastUpdatedAt: Date

    public init(
        id: UUID = UUID(),
        destinationTitle: String,
        startedAt: Date,
        phase: ActiveTripPhase = .notStarted,
        candidateOptionIDs: [UUID] = [],
        optionBeliefs: [UUID: Double] = [:],
        inferredOptionID: UUID? = nil,
        pendingChoicePointIDs: [UUID] = [],
        currentRecommendationOptionID: UUID? = nil,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.destinationTitle = destinationTitle
        self.startedAt = startedAt
        self.phase = phase
        self.candidateOptionIDs = candidateOptionIDs
        self.optionBeliefs = optionBeliefs
        self.inferredOptionID = inferredOptionID
        self.pendingChoicePointIDs = pendingChoicePointIDs
        self.currentRecommendationOptionID = currentRecommendationOptionID
        self.lastUpdatedAt = lastUpdatedAt
    }

    public func normalizedBeliefs() -> [UUID: Double] {
        let total = optionBeliefs.values.reduce(0, +)
        guard total > 0 else {
            let n = max(1, candidateOptionIDs.count)
            let uniform = 1.0 / Double(n)
            return Dictionary(uniqueKeysWithValues: candidateOptionIDs.map { ($0, uniform) })
        }
        return optionBeliefs.mapValues { $0 / total }
    }
}
