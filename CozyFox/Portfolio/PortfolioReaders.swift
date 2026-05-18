import Foundation
import TransitDomain
import TransitModels

/// App-side conformances that bridge the main-actor-isolated learning
/// stores (`ArrivalBiasStore`, `WalkingDistanceStore`) to the
/// `Sendable` reader protocols the portfolio evaluator consumes.
///
/// Both factories snapshot their underlying state at the moment of
/// construction so the returned reader can be passed across actor
/// boundaries without further hops. Each refresh tick that runs the
/// evaluator builds fresh readers; the captured state is frozen for
/// the lifetime of that tick.
///
/// Mirrors the `PreferencesStoreLikeConformance` pattern: protocol in
/// `TransitDomain`, conformance in the app target.

extension ArrivalBiasStore {
    /// Freeze the current cell map and return a `BiasCorrectionReader`
    /// the evaluator can call without re-entering the main actor.
    /// Re-call this each refresh cycle to pick up newly graded samples.
    @MainActor
    func makeBiasCorrectionReader(calendar: Calendar = .current) -> BiasCellLookupReader {
        let frozen = cells
        return BiasCellLookupReader(
            cellLookup: { key in frozen[key] },
            calendar: calendar
        )
    }
}

/// Snapshot-backed conformance. The captured `distances` dictionary is
/// the same one `WalkingDistanceStore.fresh(...)` reads through; the TTL
/// and per-user walk-speed correction are applied at lookup time so the
/// behavior matches the store's `fresh(...)` call.
///
/// `lPlatform` cases resolve to `nil` for now — the walking cache keys
/// at station granularity (`stationDestinationKey`) and callers needing
/// a platform-level walk-time must map to the parent station via
/// `LStationCatalog` before constructing the `TransitStopRef`.
struct SnapshotWalkingDistanceReader: WalkingDistanceReader {
    let distances: [String: AccessRouteDistances]
    /// Output of `WalkSpeedEstimate.confidentRatio()`. `nil` when below
    /// the confidence gate — `walkSeconds` then returns MapKit's
    /// estimate unscaled.
    let confidentWalkSpeedRatio: Double?
    let freshnessTTL: TimeInterval
    /// Reference time for TTL checks. Captured at construction so every
    /// call within one evaluator tick sees identical staleness.
    let now: Date

    func walkSeconds(
        from origin: (lat: Double, lon: Double),
        to destination: TransitStopRef
    ) -> TimeInterval? {
        let destinationKey: String
        switch destination {
        case .lStation(let id):
            destinationKey = WalkingDistanceStore.stationDestinationKey(stationId: id)
        case .lPlatform:
            // Walking cache is keyed by station, not platform. Caller
            // must resolve via `LStationCatalog` first.
            return nil
        case .bus(let id):
            destinationKey = WalkingDistanceStore.busStopDestinationKey(stopId: id)
        case .metra(let id):
            destinationKey = WalkingDistanceStore.metraStationDestinationKey(stationId: id)
        case .amtrak(let id):
            destinationKey = WalkingDistanceStore.amtrakStationDestinationKey(stationId: id)
        case .intercampus(let id):
            destinationKey = WalkingDistanceStore.intercampusStopDestinationKey(stopId: id)
        }
        let key = WalkingDistanceStore.bucketKey(origin: origin, destinationKey: destinationKey)
        guard let entry = distances[key]?.walking else { return nil }
        guard now.timeIntervalSince(entry.cachedAt) <= freshnessTTL else { return nil }
        let ratio = confidentWalkSpeedRatio ?? 1.0
        return ratio * entry.expectedTravelTime
    }
}

extension WalkingDistanceStore {
    /// Freeze the current walk-distance cache + the user's walk-speed
    /// ratio into a `Sendable` reader. Pop a fresh one each refresh
    /// cycle so newly resolved MapKit walks land in subsequent
    /// evaluations.
    @MainActor
    func makeWalkingDistanceReader(now: Date = .now) -> SnapshotWalkingDistanceReader {
        SnapshotWalkingDistanceReader(
            distances: distances,
            confidentWalkSpeedRatio: walkSpeedEstimate.confidentRatio(),
            freshnessTTL: freshnessTTL,
            now: now
        )
    }
}
