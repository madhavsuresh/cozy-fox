import Foundation

/// A free-floating Divvy e-bike (from `free_bike_status.json`).
public struct EBike: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let currentRangeMeters: Double
    public let isReserved: Bool
    public let isDisabled: Bool
    /// Present when the bike is parked at a station. Many Divvy snapshots
    /// don't populate this; treat absence as "free-floating".
    public let stationId: String?

    public init(
        id: String,
        latitude: Double,
        longitude: Double,
        currentRangeMeters: Double,
        isReserved: Bool,
        isDisabled: Bool,
        stationId: String? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.currentRangeMeters = currentRangeMeters
        self.isReserved = isReserved
        self.isDisabled = isDisabled
        self.stationId = stationId
    }

    public var rangeMiles: Double { currentRangeMeters / 1609.344 }
}

/// A Divvy docking station and its real-time availability.
public struct BikeStation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let capacity: Int
    public let eBikesAvailable: Int
    public let classicBikesAvailable: Int
    public let docksAvailable: Int
    public let isRenting: Bool
    public let isReturning: Bool
    public let lastReported: Date

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        capacity: Int,
        eBikesAvailable: Int,
        classicBikesAvailable: Int,
        docksAvailable: Int,
        isRenting: Bool,
        isReturning: Bool,
        lastReported: Date
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.capacity = capacity
        self.eBikesAvailable = eBikesAvailable
        self.classicBikesAvailable = classicBikesAvailable
        self.docksAvailable = docksAvailable
        self.isRenting = isRenting
        self.isReturning = isReturning
        self.lastReported = lastReported
    }

    public var isScarce: Bool { eBikesAvailable <= 2 }
}

/// Result of "what's the best e-bike option right now from `from`?" Precomputed
/// during refresh and stored for the widget to read synchronously.
public struct NearestBikePick: Codable, Sendable, Hashable {
    public let station: BikeStation
    public let walkingDistanceMeters: Double
    public let bestRangeMeters: Double
    public let freeFloatingNearby: Int
    public let computedAt: Date

    public init(
        station: BikeStation,
        walkingDistanceMeters: Double,
        bestRangeMeters: Double,
        freeFloatingNearby: Int,
        computedAt: Date
    ) {
        self.station = station
        self.walkingDistanceMeters = walkingDistanceMeters
        self.bestRangeMeters = bestRangeMeters
        self.freeFloatingNearby = freeFloatingNearby
        self.computedAt = computedAt
    }

    public var bestRangeMiles: Double { bestRangeMeters / 1609.344 }
    public var walkingMinutes: Int {
        // 1.4 m/s typical walking pace = 84 m/min.
        max(1, Int((walkingDistanceMeters / 84.0).rounded()))
    }
}
