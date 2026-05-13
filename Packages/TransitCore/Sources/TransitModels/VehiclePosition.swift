import Foundation

/// Live position of a single CTA train run or bus vehicle. Sourced from
/// `ttpositions.aspx` for trains and `getvehicles` for buses.
public struct VehiclePosition: Codable, Sendable, Hashable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        case train, bus
    }

    /// Run number for trains (e.g. "401"), vehicle id for buses (e.g. "1841").
    public let id: String
    public let mode: Mode
    /// Line raw value for trains ("red", "blue", …), route name for buses ("22").
    public let route: String
    public let latitude: Double
    public let longitude: Double
    /// Compass heading degrees if reported, else nil.
    public let heading: Int?
    public let destinationName: String?
    /// Next stop id for trains (`nextStpId`) or bus stop id reported by the
    /// bus tracker (`stopId`), if available.
    public let nextStopId: Int?
    public let observedAt: Date

    public init(
        id: String,
        mode: Mode,
        route: String,
        latitude: Double,
        longitude: Double,
        heading: Int? = nil,
        destinationName: String? = nil,
        nextStopId: Int? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.mode = mode
        self.route = route
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.destinationName = destinationName
        self.nextStopId = nextStopId
        self.observedAt = observedAt
    }
}
