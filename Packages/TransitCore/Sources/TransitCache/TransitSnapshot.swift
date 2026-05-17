import Foundation
import TransitModels

/// A read-only snapshot the widget consumes. Pure value types — never holds
/// SwiftData objects across actor / process boundaries.
public struct TransitSnapshot: Sendable, Hashable {
    public var trainArrivals: [Arrival]
    public var busPredictions: [BusPrediction]
    public var metraPredictions: [MetraPrediction]
    public var intercampusArrivals: [IntercampusArrival]
    public var vehiclePositions: [VehiclePosition]
    public var nearestBike: NearestBikePick?
    public var nearbyBikePicks: [NearestBikePick]
    public var nearbyFreeBikePicks: [NearestFreeBikePick]
    public var activeAlerts: [ServiceAlert]
    public var busDetours: [BusDetour]
    public var busPatterns: [BusPattern]
    /// Aggregated per-(route, direction, stop, horizon, hour-of-week)
    /// residual quantile bins. Read by `BusPredictionCalibrator` to apply
    /// a personal q50 shift to displayed bus minutes. Phase 4a writes;
    /// phase 4b reads.
    public var busResidualBins: [BusResidualQuantileBin]
    /// Per-stop detour-membership state (which detour IDs add/remove
    /// each stop). Phase 2b reads this to abstain on
    /// stop-removed-by-detour predictions. Empty when no pinned stops
    /// have detour state.
    public var busStopDetourStates: [BusStopDetourState]
    public var trainsFetchedAt: Date?
    public var busesFetchedAt: Date?
    public var metraFetchedAt: Date?
    public var intercampusFetchedAt: Date?
    public var bikesFetchedAt: Date?
    public var alertsFetchedAt: Date?
    public var busDetoursFetchedAt: Date?
    public var busPatternsFetchedAt: Date?

    public init(
        trainArrivals: [Arrival] = [],
        busPredictions: [BusPrediction] = [],
        metraPredictions: [MetraPrediction] = [],
        intercampusArrivals: [IntercampusArrival] = [],
        vehiclePositions: [VehiclePosition] = [],
        nearestBike: NearestBikePick? = nil,
        nearbyBikePicks: [NearestBikePick] = [],
        nearbyFreeBikePicks: [NearestFreeBikePick] = [],
        activeAlerts: [ServiceAlert] = [],
        busDetours: [BusDetour] = [],
        busPatterns: [BusPattern] = [],
        busResidualBins: [BusResidualQuantileBin] = [],
        busStopDetourStates: [BusStopDetourState] = [],
        trainsFetchedAt: Date? = nil,
        busesFetchedAt: Date? = nil,
        metraFetchedAt: Date? = nil,
        intercampusFetchedAt: Date? = nil,
        bikesFetchedAt: Date? = nil,
        alertsFetchedAt: Date? = nil,
        busDetoursFetchedAt: Date? = nil,
        busPatternsFetchedAt: Date? = nil
    ) {
        self.trainArrivals = trainArrivals
        self.busPredictions = busPredictions
        self.metraPredictions = metraPredictions
        self.intercampusArrivals = intercampusArrivals
        self.vehiclePositions = vehiclePositions
        self.nearestBike = nearestBike
        self.nearbyBikePicks = nearbyBikePicks
        self.nearbyFreeBikePicks = nearbyFreeBikePicks
        self.activeAlerts = activeAlerts
        self.busDetours = busDetours
        self.busPatterns = busPatterns
        self.busResidualBins = busResidualBins
        self.busStopDetourStates = busStopDetourStates
        self.trainsFetchedAt = trainsFetchedAt
        self.busesFetchedAt = busesFetchedAt
        self.metraFetchedAt = metraFetchedAt
        self.intercampusFetchedAt = intercampusFetchedAt
        self.bikesFetchedAt = bikesFetchedAt
        self.alertsFetchedAt = alertsFetchedAt
        self.busDetoursFetchedAt = busDetoursFetchedAt
        self.busPatternsFetchedAt = busPatternsFetchedAt
    }

    public static let empty = TransitSnapshot()

    public var nearbyBikeOptions: [NearbyBikeOption] {
        (nearbyBikePicks.map(NearbyBikeOption.station)
            + nearbyFreeBikePicks.map(NearbyBikeOption.freeFloating))
            .sorted { lhs, rhs in
                if lhs.walkingDistanceMeters != rhs.walkingDistanceMeters {
                    return lhs.walkingDistanceMeters < rhs.walkingDistanceMeters
                }
                return lhs.id < rhs.id
            }
    }

    /// Soft "stale" indicator the widget uses.
    public func isAnythingStale(now: Date = .now, ttl: TimeInterval = 300) -> Bool {
        let dates: [Date?] = [
            trainsFetchedAt,
            busesFetchedAt,
            metraFetchedAt,
            intercampusFetchedAt,
            bikesFetchedAt,
            alertsFetchedAt,
        ]
        return dates.compactMap { $0 }.contains { now.timeIntervalSince($0) > ttl }
    }
}
