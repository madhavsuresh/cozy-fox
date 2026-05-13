import Foundation

/// A CTA "L" station as exposed by the Train Tracker.
public struct LStation: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let servedLines: [LineColor]

    public init(
        id: Int,
        name: String,
        latitude: Double,
        longitude: Double,
        servedLines: [LineColor]
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.servedLines = servedLines
    }
}

/// A direction-specific platform at an L station.
public struct LPlatform: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let stationId: Int
    public let line: LineColor
    public let directionLabel: String

    public init(id: Int, stationId: Int, line: LineColor, directionLabel: String) {
        self.id = id
        self.stationId = stationId
        self.line = line
        self.directionLabel = directionLabel
    }
}

/// A CTA bus stop.
public struct BusStop: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let route: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let directionLabel: String

    public init(
        id: Int,
        route: String,
        name: String,
        latitude: Double,
        longitude: Double,
        directionLabel: String
    ) {
        self.id = id
        self.route = route
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.directionLabel = directionLabel
    }
}
