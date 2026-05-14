import Foundation
import TransitModels

/// A read-only snapshot the widget consumes. Pure value types — never holds
/// SwiftData objects across actor / process boundaries.
public struct TransitSnapshot: Sendable, Hashable {
    public var trainArrivals: [Arrival]
    public var busPredictions: [BusPrediction]
    public var metraPredictions: [MetraPrediction]
    public var nearestBike: NearestBikePick?
    public var nearbyBikePicks: [NearestBikePick]
    public var nearbyFreeBikePicks: [NearestFreeBikePick]
    public var activeAlerts: [ServiceAlert]
    public var trainsFetchedAt: Date?
    public var busesFetchedAt: Date?
    public var metraFetchedAt: Date?
    public var bikesFetchedAt: Date?
    public var alertsFetchedAt: Date?

    public init(
        trainArrivals: [Arrival] = [],
        busPredictions: [BusPrediction] = [],
        metraPredictions: [MetraPrediction] = [],
        nearestBike: NearestBikePick? = nil,
        nearbyBikePicks: [NearestBikePick] = [],
        nearbyFreeBikePicks: [NearestFreeBikePick] = [],
        activeAlerts: [ServiceAlert] = [],
        trainsFetchedAt: Date? = nil,
        busesFetchedAt: Date? = nil,
        metraFetchedAt: Date? = nil,
        bikesFetchedAt: Date? = nil,
        alertsFetchedAt: Date? = nil
    ) {
        self.trainArrivals = trainArrivals
        self.busPredictions = busPredictions
        self.metraPredictions = metraPredictions
        self.nearestBike = nearestBike
        self.nearbyBikePicks = nearbyBikePicks
        self.nearbyFreeBikePicks = nearbyFreeBikePicks
        self.activeAlerts = activeAlerts
        self.trainsFetchedAt = trainsFetchedAt
        self.busesFetchedAt = busesFetchedAt
        self.metraFetchedAt = metraFetchedAt
        self.bikesFetchedAt = bikesFetchedAt
        self.alertsFetchedAt = alertsFetchedAt
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
        let dates: [Date?] = [trainsFetchedAt, busesFetchedAt, metraFetchedAt, bikesFetchedAt, alertsFetchedAt]
        return dates.compactMap { $0 }.contains { now.timeIntervalSince($0) > ttl }
    }
}
