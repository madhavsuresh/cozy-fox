import Foundation

public struct ChoicePoint: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let title: String
    public let location: PlannerCoordinate?
    public let decisionByTime: Date?
    public let candidateIDs: [UUID]
    public let recommendedCandidateID: UUID?
    public let recommendationReason: String?
    public let hysteresisHoldUntil: Date?
    public let confidence: Double

    public init(
        id: UUID = UUID(),
        title: String,
        location: PlannerCoordinate? = nil,
        decisionByTime: Date? = nil,
        candidateIDs: [UUID],
        recommendedCandidateID: UUID? = nil,
        recommendationReason: String? = nil,
        hysteresisHoldUntil: Date? = nil,
        confidence: Double
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.decisionByTime = decisionByTime
        self.candidateIDs = candidateIDs
        self.recommendedCandidateID = recommendedCandidateID
        self.recommendationReason = recommendationReason
        self.hysteresisHoldUntil = hysteresisHoldUntil
        self.confidence = max(0, min(1, confidence))
    }
}
