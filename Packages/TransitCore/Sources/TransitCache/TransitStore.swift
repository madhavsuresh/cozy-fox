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

    public func replaceBusDetours(_ detours: [BusDetour]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedBusDetour.self)
        for detour in detours {
            ctx.insert(CachedBusDetour(detour: detour, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceBusPatterns(_ patterns: [BusPattern]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedBusPattern.self)
        for pattern in patterns {
            ctx.insert(CachedBusPattern(pattern: pattern, fetchedAt: now))
        }
        try? ctx.save()
    }

    public func replaceBusStopDetourStates(_ states: [BusStopDetourState]) {
        let now = Date()
        let ctx = ModelContext(container)
        try? ctx.delete(model: CachedBusStopDetourState.self)
        for state in states {
            ctx.insert(CachedBusStopDetourState(state: state, fetchedAt: now))
        }
        try? ctx.save()
    }

    /// Records a single raw residual and recomputes the corresponding
    /// `BusResidualQuantileBin`. Cheap at one user's volume (each bin holds
    /// tens of samples) so we recompute on every write rather than
    /// scheduling a nightly compaction. See `docs/BUS_RELIABILITY.md`.
    public func recordBusResidual(_ residual: BusPredictionResidual) {
        let ctx = ModelContext(container)
        ctx.insert(CachedBusPredictionResidual(residual: residual))
        try? ctx.save()
        recomputeResidualBin(
            route: residual.route,
            directionName: residual.directionName,
            stopId: residual.stopId,
            horizonBucket: residual.horizonBucket,
            hourOfWeek: residual.hourOfWeek,
            using: ctx
        )
    }

    /// Look up the residual quantile bin for an exact stratum. Returns nil
    /// when the bin doesn't exist or hasn't accumulated samples — callers
    /// should fall back to coarser bins (see `latestResidualBin(...)`).
    public func residualBin(
        route: String,
        directionName: String,
        stopId: Int,
        horizonBucket: BusHorizonBucket,
        hourOfWeek: Int
    ) -> BusResidualQuantileBin? {
        let key = BusResidualQuantileBin(
            route: route,
            directionName: directionName,
            stopId: stopId,
            horizonBucket: horizonBucket,
            hourOfWeek: hourOfWeek,
            sampleCount: 0, q10Seconds: 0, q50Seconds: 0, q90Seconds: 0,
            lastUpdated: .distantPast
        ).key
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<CachedBusResidualQuantileBin>(
            predicate: #Predicate { $0.key == key }
        )
        return (try? ctx.fetch(descriptor))?.first?.asModel
    }

    /// All raw residuals — primarily for debug surfaces and tests. The
    /// store doesn't keep these forever; pruning is a phase 4b concern.
    public func allBusResiduals() -> [BusPredictionResidual] {
        let ctx = ModelContext(container)
        return ((try? ctx.fetch(FetchDescriptor<CachedBusPredictionResidual>())) ?? [])
            .compactMap(\.asModel)
    }

    /// All aggregated bins — for the debug surface and tests.
    public func allBusResidualBins() -> [BusResidualQuantileBin] {
        let ctx = ModelContext(container)
        return ((try? ctx.fetch(FetchDescriptor<CachedBusResidualQuantileBin>())) ?? [])
            .compactMap(\.asModel)
    }

    private func recomputeResidualBin(
        route: String,
        directionName: String,
        stopId: Int,
        horizonBucket: BusHorizonBucket,
        hourOfWeek: Int,
        using ctx: ModelContext
    ) {
        let bucketRaw = horizonBucket.rawValue
        let descriptor = FetchDescriptor<CachedBusPredictionResidual>(
            predicate: #Predicate {
                $0.route == route
                    && $0.directionName == directionName
                    && $0.stopId == stopId
                    && $0.horizonBucketRaw == bucketRaw
                    && $0.hourOfWeek == hourOfWeek
            }
        )
        let rows = (try? ctx.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return }
        let samples = rows.map(\.residualSeconds).sorted()
        let q10 = quantile(samples, 0.10)
        let q50 = quantile(samples, 0.50)
        let q90 = quantile(samples, 0.90)
        let bin = BusResidualQuantileBin(
            route: route,
            directionName: directionName,
            stopId: stopId,
            horizonBucket: horizonBucket,
            hourOfWeek: hourOfWeek,
            sampleCount: samples.count,
            q10Seconds: q10,
            q50Seconds: q50,
            q90Seconds: q90,
            lastUpdated: Date()
        )
        let existingKey = bin.key
        let existing = (try? ctx.fetch(FetchDescriptor<CachedBusResidualQuantileBin>(
            predicate: #Predicate { $0.key == existingKey }
        )))?.first
        if let existing {
            existing.sampleCount = bin.sampleCount
            existing.q10Seconds = bin.q10Seconds
            existing.q50Seconds = bin.q50Seconds
            existing.q90Seconds = bin.q90Seconds
            existing.lastUpdated = bin.lastUpdated
        } else {
            ctx.insert(CachedBusResidualQuantileBin(bin: bin))
        }
        try? ctx.save()
    }

    /// Linear-interpolation quantile on a sorted array. With ~20 samples
    /// per bin this is plenty accurate without a streaming P² estimator.
    private func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
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
