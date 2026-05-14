import Foundation
import SwiftData
import TransitModels

/// Facade actor that owns the SwiftData container and exposes high-level
/// write methods. Only used from the app target (which knows about the API
/// clients); the widget reads via `SnapshotReader` directly.
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

    @MainActor
    private func context() -> ModelContext { ModelContext(container) }

    /// Replace cached arrivals atomically. `Sendable` Arrival values cross the
    /// actor boundary; SwiftData writes happen on the main actor for safety.
    public func replaceTrainArrivals(_ arrivals: [Arrival]) async {
        let now = Date()
        await MainActor.run {
            let ctx = ModelContext(container)
            try? ctx.delete(model: CachedTrainArrival.self)
            for arrival in arrivals {
                ctx.insert(CachedTrainArrival(arrival: arrival, fetchedAt: now))
            }
            try? ctx.save()
        }
    }

    public func replaceBusPredictions(_ predictions: [BusPrediction]) async {
        let now = Date()
        await MainActor.run {
            let ctx = ModelContext(container)
            try? ctx.delete(model: CachedBusPrediction.self)
            for prediction in predictions {
                ctx.insert(CachedBusPrediction(prediction: prediction, fetchedAt: now))
            }
            try? ctx.save()
        }
    }

    public func replaceMetraPredictions(_ predictions: [MetraPrediction]) async {
        let now = Date()
        await MainActor.run {
            let ctx = ModelContext(container)
            try? ctx.delete(model: CachedMetraPrediction.self)
            for prediction in predictions {
                ctx.insert(CachedMetraPrediction(prediction: prediction, fetchedAt: now))
            }
            try? ctx.save()
        }
    }

    public func replaceAlerts(_ alerts: [ServiceAlert]) async {
        let now = Date()
        await MainActor.run {
            let ctx = ModelContext(container)
            try? ctx.delete(model: CachedAlert.self)
            for alert in alerts {
                ctx.insert(CachedAlert(alert: alert, fetchedAt: now))
            }
            try? ctx.save()
        }
    }

    /// Append-only — historical snapshots for the future churn estimator. We
    /// also prune rows older than 14 days.
    public func recordStationSnapshots(_ stations: [BikeStation]) async {
        let now = Date()
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        await MainActor.run {
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
    }

    public func replaceNearestBike(_ pick: NearestBikePick?) async {
        await replaceNearbyBikePicks(pick.map { [$0] } ?? [])
    }

    /// Replaces the cached "closest e-bikes" list (rank 0 = closest). The
    /// dashboard reads all rows; the widget / Live Activity reads rank 0.
    public func replaceNearbyBikePicks(
        _ picks: [NearestBikePick],
        freeFloatingPicks: [NearestFreeBikePick] = []
    ) async {
        await MainActor.run {
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
    }

    /// Convenience read for the main app. Widget should use `SnapshotReader`.
    public func currentSnapshot(now: Date = .now) async -> TransitSnapshot {
        await MainActor.run {
            SnapshotReader(container: container).loadSnapshot(now: now)
        }
    }
}
