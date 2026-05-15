import Foundation
import TransitLocation
import TransitModels

/// Phase 4 boarding detector. Pure function: given (previousMotion,
/// currentMotion, lastKnownLocation, stationCatalog, now), decides whether
/// the user has just boarded a CTA "L" train at one of the catalog
/// stations and returns the corresponding `BoardingEvent`.
///
/// The detector is intentionally state-free. The caller owns the
/// previous-motion bookkeeping (one `MotionContext` per refresh cycle).
/// Sendable and main-actor-free so the call site can dispatch off-main
/// if it wants — though in practice the `RefreshCoordinator` invokes it
/// inline on the main actor.
///
/// **Detection rule** (must all hold to emit an event):
///   1. Motion transitioned from a non-vehicle state (`stationary` or
///      `walking`) into a vehicle-like state (`automotive` or `cycling`).
///      Cycling is included because the Core Motion classifier can wobble
///      between cycling and automotive at low speeds; we accept the
///      occasional false positive — Phase 4 train-only mistakes write to
///      train bias cells incorrectly only at the margin.
///   2. `currentLocation` is non-nil and within `maxRadiusMeters` of an
///      `LStation` in the catalog.
///   3. Of all stations within radius, the closest one wins (tie-breaks
///      by stable catalog order, which is fine — the catalog is small
///      and ties are extraordinarily rare in practice).
///
/// Otherwise: returns `nil`.
///
/// **Known false positives** (accepted in Phase 4):
///   - User parks at a station, walks to platform, gets on a train:
///     `stationary → walking → stationary → automotive` — the last
///     transition is the boarding moment and is correctly detected.
///   - User boards a bus near a train station: writes to train bias
///     cells. Rare in Chicago's station-bus geometry; acceptable noise.
///
/// **Known false negatives**:
///   - User in a car drives past a station: gated out because driving
///     stays `automotive → automotive` (no transition).
///   - Phone in pocket without a clean stationary frame: missed; passive
///     grader still works.
///   - App backgrounded across the boarding moment: missed; we poll only
///     during foreground refresh cycles.
///   - Boarding at a station >`maxRadiusMeters` away: missed.
public struct BoardingDetector: Sendable {
    public struct BoardingEvent: Sendable, Hashable {
        public let stationId: Int
        public let observedAt: Date

        public init(stationId: Int, observedAt: Date) {
            self.stationId = stationId
            self.observedAt = observedAt
        }
    }

    public init() {}

    /// Returns a boarding event when the motion transition + location
    /// proximity criteria are met, else `nil`. Pure — caller owns the
    /// previous-motion state.
    public func detect(
        previousMotion: MotionContext,
        currentMotion: MotionContext,
        currentLocation: LastKnownLocation?,
        stationCatalog: [LStation] = LStationCatalog.all,
        maxRadiusMeters: Double = RegionIdentifiers.radiusMeters,
        now: Date = .now
    ) -> BoardingEvent? {
        guard isBoardingTransition(previous: previousMotion, current: currentMotion) else {
            return nil
        }
        guard let location = currentLocation else { return nil }
        guard !stationCatalog.isEmpty, maxRadiusMeters > 0 else { return nil }

        // One-pass bounded-best: track the closest station within radius.
        // Same pattern as `NearestStationResolver.boundedNearest` but
        // collapsed to limit=1 so we don't allocate a results array.
        var bestStationId: Int?
        var bestDistance: Double = .infinity
        for station in stationCatalog {
            let distance = Distance.meters(
                from: (location.latitude, location.longitude),
                to: (station.latitude, station.longitude)
            )
            guard distance <= maxRadiusMeters else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestStationId = station.id
            }
        }
        guard let stationId = bestStationId else { return nil }
        return BoardingEvent(stationId: stationId, observedAt: now)
    }

    /// True iff motion went from a non-vehicle state to a vehicle-like
    /// state. Unknown on either side → false (we don't infer transitions
    /// when classifier confidence is missing).
    private func isBoardingTransition(
        previous: MotionContext,
        current: MotionContext
    ) -> Bool {
        let fromNonVehicle = (previous == .stationary || previous == .walking)
        let toVehicle = (current == .automotive || current == .cycling)
        return fromNonVehicle && toVehicle
    }
}
