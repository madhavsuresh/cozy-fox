import Foundation
import SwiftData
import TransitModels

/// Facade actor that owns the SwiftData container and exposes high-level
/// write methods. Only used from the app target (which knows about the API
/// clients); the widget reads via `SnapshotReader` directly.
///
/// Writes happen on the actor's own executor — *not* the main actor — so a
/// 30-second refresh cycle that fans out 6 `replace*` calls in parallel
/// doesn't stall scrolling or animations on the dashboard. SwiftData's
/// `ModelContext` is bound to the thread/actor it's created on; we
/// instantiate a fresh context per call so each replace operates in
/// isolation.
public actor TransitStore {
    public let container: ModelContainer
    private let preferences: PreferencesStore

    public init(container: ModelContainer, preferences: PreferencesStore = PreferencesStore()) {
        self.container = container
        self.preferences = preferences
    }

    public static func live() throws -> TransitStore {
        let container = try ModelContainer.sharedAppGroup()
        return TransitStore(container: container)
    }

    /// Replace cached arrivals atomically. Runs on the actor's executor so
    /// the main thread stays free for scrolling and live animations.
    public func replaceTrainArrivals(_ arrivals: [Arrival]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedTrainArrival.self)
        for arrival in arrivals {
            ctx.insert(CachedTrainArrival(arrival: arrival, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceBusPredictions(_ predictions: [BusPrediction]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedBusPrediction.self)
        for prediction in predictions {
            ctx.insert(CachedBusPrediction(prediction: prediction, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceMetraPredictions(_ predictions: [MetraPrediction]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedMetraPrediction.self)
        for prediction in predictions {
            ctx.insert(CachedMetraPrediction(prediction: prediction, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceIntercampusArrivals(_ arrivals: [IntercampusArrival]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedIntercampusArrival.self)
        for arrival in arrivals {
            ctx.insert(CachedIntercampusArrival(arrival: arrival, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceVehiclePositions(_ positions: [VehiclePosition]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedVehiclePosition.self)
        for position in positions {
            ctx.insert(CachedVehiclePosition(position: position, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceAlerts(_ alerts: [ServiceAlert]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedAlert.self)
        for alert in alerts {
            ctx.insert(CachedAlert(alert: alert, fetchedAt: now))
        }
        try? ctx.save()
    }

    /// Append-only — historical snapshots for the future churn estimator. We
    /// also prune rows older than 14 days.
    public func recordStationSnapshots(_ stations: [BikeStation]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let ctx = ModelContext(container)
        for station in stations {
            ctx.insert(CachedEBikeStation(station: station, snappedAt: now))
        }
        let descriptor = FetchDescriptor<CachedEBikeStation>(
            predicate: #Predicate { $0.snappedAt < cutoff }
        )
        if let stale = try? ctx.fetch(descriptor) {
            for row in stale { ctx.delete(row) }
        }
        try? ctx.save()
    }

    public func replaceNearestBike(_ pick: NearestBikePick?) {
        replaceNearbyBikePicks(pick.map { [$0] } ?? [])
    }

    /// Replaces the cached "closest e-bikes" list (rank 0 = closest). The
    /// dashboard reads all rows; the widget / Live Activity reads rank 0.
    public func replaceNearbyBikePicks(
        _ picks: [NearestBikePick],
        freeFloatingPicks: [NearestFreeBikePick] = []
    ) {
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedNearestBike.self)
        try? ctx.delete(model: CachedNearestFreeBike.self)
        for (rank, pick) in picks.enumerated() {
            ctx.insert(CachedNearestBike(pick: pick, rank: rank))
        }
        for (rank, pick) in freeFloatingPicks.enumerated() {
            ctx.insert(CachedNearestFreeBike(pick: pick, rank: rank))
        }
        try? ctx.save()
    }

    /// Convenience read for the main app. Widget should use `SnapshotReader`.
    public func currentSnapshot(now: Date = .now) -> TransitSnapshot {
        SnapshotReader(container: container).loadSnapshot(now: now)
    }
}
