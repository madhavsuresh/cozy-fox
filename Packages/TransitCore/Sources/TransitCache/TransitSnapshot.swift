import Foundation
import TransitModels

/// A read-only snapshot the widget consumes. Pure value types — never holds
/// SwiftData objects across actor / process boundaries.
public struct TransitSnapshot: Sendable, Hashable {
    public var trainArrivals: [Arrival]
    public var busPredictions: [BusPrediction]
    public var nearestBike: NearestBikePick?
    public var activeAlerts: [ServiceAlert]
    public var trainsFetchedAt: Date?
    public var busesFetchedAt: Date?
    public var bikesFetchedAt: Date?
    public var alertsFetchedAt: Date?

    public init(
        trainArrivals: [Arrival] = [],
        busPredictions: [BusPrediction] = [],
        nearestBike: NearestBikePick? = nil,
        activeAlerts: [ServiceAlert] = [],
        trainsFetchedAt: Date? = nil,
        busesFetchedAt: Date? = nil,
        bikesFetchedAt: Date? = nil,
        alertsFetchedAt: Date? = nil
    ) {
        self.trainArrivals = trainArrivals
        self.busPredictions = busPredictions
        self.nearestBike = nearestBike
        self.activeAlerts = activeAlerts
        self.trainsFetchedAt = trainsFetchedAt
        self.busesFetchedAt = busesFetchedAt
        self.bikesFetchedAt = bikesFetchedAt
        self.alertsFetchedAt = alertsFetchedAt
    }

    public static let empty = TransitSnapshot()

    /// Soft "stale" indicator the widget uses.
    public func isAnythingStale(now: Date = .now, ttl: TimeInterval = 300) -> Bool {
        let dates: [Date?] = [trainsFetchedAt, busesFetchedAt, bikesFetchedAt, alertsFetchedAt]
        return dates.compactMap { $0 }.contains { now.timeIntervalSince($0) > ttl }
    }
}
