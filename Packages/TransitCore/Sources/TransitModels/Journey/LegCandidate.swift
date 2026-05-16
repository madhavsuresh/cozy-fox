import Foundation

public enum LegMode: String, Sendable, Hashable, Codable, CaseIterable {
    case walk
    case ctaBus
    case ctaTrain
    case metra
    case intercampus
    case divvyClassic
    case divvyEBike
    case freeBikeParking
    case finalMile
}

public struct LegCandidate: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let mode: LegMode
    public let displayLabel: String
    public let routeHint: String?
    public let fromPoint: JourneyPoint
    public let toPoint: JourneyPoint

    public init(
        id: UUID = UUID(),
        mode: LegMode,
        displayLabel: String,
        routeHint: String? = nil,
        fromPoint: JourneyPoint,
        toPoint: JourneyPoint
    ) {
        self.id = id
        self.mode = mode
        self.displayLabel = displayLabel
        self.routeHint = routeHint
        self.fromPoint = fromPoint
        self.toPoint = toPoint
    }
}
