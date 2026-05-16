import Foundation

public enum LineHealthState: String, Sendable, Hashable, Codable, CaseIterable {
    case normal
    case longGap
    case bunchedThenGap
    case compressed
    case degraded
    case recovering
    case feedStale
    case insufficientData
}

public struct LineHealthSnapshot: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let route: String
    public let direction: String?
    public let state: LineHealthState
    public let confidence: Double
    public let generatedAt: Date
    public let summary: String?

    public init(
        id: UUID = UUID(),
        route: String,
        direction: String? = nil,
        state: LineHealthState,
        confidence: Double,
        generatedAt: Date,
        summary: String? = nil
    ) {
        self.id = id
        self.route = route
        self.direction = direction
        self.state = state
        self.confidence = max(0, min(1, confidence))
        self.generatedAt = generatedAt
        self.summary = summary
    }
}
