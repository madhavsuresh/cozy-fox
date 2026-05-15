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
    public var isFreeFloating: Bool { stationId?.isEmpty ?? true }
}

public struct EBikeChargeSummary: Codable, Sendable, Hashable {
    public let sortedRangeMeters: [Double]

    public init?(bikes: [EBike]) {
        let ranges = bikes
            .map(\.currentRangeMeters)
            .filter { $0 > 0 }
            .sorted()
        guard !ranges.isEmpty else { return nil }
        self.sortedRangeMeters = ranges
    }

    public var count: Int { sortedRangeMeters.count }
    public var minRangeMeters: Double { sortedRangeMeters.first ?? 0 }
    public var maxRangeMeters: Double { sortedRangeMeters.last ?? 0 }
    public var medianRangeMeters: Double {
        guard !sortedRangeMeters.isEmpty else { return 0 }
        let middle = sortedRangeMeters.count / 2
        if sortedRangeMeters.count.isMultiple(of: 2) {
            return (sortedRangeMeters[middle - 1] + sortedRangeMeters[middle]) / 2
        }
        return sortedRangeMeters[middle]
    }
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
    public let dockedBikes: [EBike]
    public let freeFloatingNearby: Int
    public let nearbyFreeFloatingBikes: [EBike]
    public let computedAt: Date

    public init(
        station: BikeStation,
        walkingDistanceMeters: Double,
        bestRangeMeters: Double,
        dockedBikes: [EBike] = [],
        freeFloatingNearby: Int? = nil,
        nearbyFreeFloatingBikes: [EBike] = [],
        computedAt: Date
    ) {
        self.station = station
        self.walkingDistanceMeters = walkingDistanceMeters
        self.bestRangeMeters = bestRangeMeters
        self.dockedBikes = dockedBikes
        self.freeFloatingNearby = freeFloatingNearby ?? nearbyFreeFloatingBikes.count
        self.nearbyFreeFloatingBikes = nearbyFreeFloatingBikes
        self.computedAt = computedAt
    }

    enum CodingKeys: String, CodingKey {
        case station
        case walkingDistanceMeters
        case bestRangeMeters
        case dockedBikes
        case freeFloatingNearby
        case nearbyFreeFloatingBikes
        case computedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        station = try container.decode(BikeStation.self, forKey: .station)
        walkingDistanceMeters = try container.decode(Double.self, forKey: .walkingDistanceMeters)
        bestRangeMeters = try container.decode(Double.self, forKey: .bestRangeMeters)
        dockedBikes = try container.decodeIfPresent([EBike].self, forKey: .dockedBikes) ?? []
        let decodedFreeBikes = try container.decodeIfPresent([EBike].self, forKey: .nearbyFreeFloatingBikes) ?? []
        freeFloatingNearby = try container.decodeIfPresent(Int.self, forKey: .freeFloatingNearby) ?? decodedFreeBikes.count
        nearbyFreeFloatingBikes = decodedFreeBikes
        computedAt = try container.decode(Date.self, forKey: .computedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(station, forKey: .station)
        try container.encode(walkingDistanceMeters, forKey: .walkingDistanceMeters)
        try container.encode(bestRangeMeters, forKey: .bestRangeMeters)
        try container.encode(dockedBikes, forKey: .dockedBikes)
        try container.encode(freeFloatingNearby, forKey: .freeFloatingNearby)
        try container.encode(nearbyFreeFloatingBikes, forKey: .nearbyFreeFloatingBikes)
        try container.encode(computedAt, forKey: .computedAt)
    }

    public var bestRangeMiles: Double { bestRangeMeters / 1609.344 }
    public var totalEBikesAvailable: Int { station.eBikesAvailable }
    public var dockedChargeSummary: EBikeChargeSummary? { EBikeChargeSummary(bikes: dockedBikes) }
    public var walkingMinutes: Int {
        // 1.4 m/s typical walking pace = 84 m/min.
        max(1, Int((walkingDistanceMeters / 84.0).rounded()))
    }
}

public struct NearestFreeBikePick: Codable, Sendable, Hashable, Identifiable {
    public let bike: EBike
    public let walkingDistanceMeters: Double
    public let computedAt: Date

    public init(
        bike: EBike,
        walkingDistanceMeters: Double,
        computedAt: Date
    ) {
        self.bike = bike
        self.walkingDistanceMeters = walkingDistanceMeters
        self.computedAt = computedAt
    }

    public var id: String { bike.id }
    public var bestRangeMiles: Double { bike.rangeMiles }
    public var walkingMinutes: Int {
        max(1, Int((walkingDistanceMeters / 84.0).rounded()))
    }
}

/// Transient in-memory snapshot of the latest Divvy GBFS fetch. Held by
/// `RefreshCoordinator` (not SwiftData) because the per-station / per-bike
/// rows would otherwise balloon the persistent store — the dashboard's trip
/// chips need the *current* inventory, not a 14-day history.
public struct BikeInventorySnapshot: Sendable, Hashable {
    public var stations: [BikeStation]
    public var eBikes: [EBike]
    public var fetchedAt: Date?

    public init(
        stations: [BikeStation] = [],
        eBikes: [EBike] = [],
        fetchedAt: Date? = nil
    ) {
        self.stations = stations
        self.eBikes = eBikes
        self.fetchedAt = fetchedAt
    }

    public static let empty = BikeInventorySnapshot()
}

public enum NearbyBikeOption: Sendable, Hashable, Identifiable {
    case station(NearestBikePick)
    case freeFloating(NearestFreeBikePick)

    public var id: String {
        switch self {
        case .station(let pick): "station-\(pick.station.id)"
        case .freeFloating(let pick): "free-\(pick.bike.id)"
        }
    }

    public var walkingDistanceMeters: Double {
        switch self {
        case .station(let pick): pick.walkingDistanceMeters
        case .freeFloating(let pick): pick.walkingDistanceMeters
        }
    }

    public var walkingMinutes: Int {
        switch self {
        case .station(let pick): pick.walkingMinutes
        case .freeFloating(let pick): pick.walkingMinutes
        }
    }
}
