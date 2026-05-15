import Foundation

/// Nonverbal confidence metadata for arrivals. Surfaces may use this to vary
/// dot weight/opacity while keeping user-facing copy unchanged.
public struct ArrivalConfidenceMark: Codable, Sendable, Hashable, Identifiable {
    public enum Tone: String, Codable, Sendable, Hashable {
        case strong
        case normal
        case weak
    }

    public let id: String
    public let arrivalAt: Date
    public let score: Double
    public let tone: Tone

    public init(id: String, arrivalAt: Date, score: Double, tone: Tone) {
        self.id = id
        self.arrivalAt = arrivalAt
        self.score = min(1, max(0, score))
        self.tone = tone
    }
}
