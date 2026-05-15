import Foundation
import TransitDomain
import TransitModels

/// Phase 5b — bike-speed counterpart of `WalkSpeedTracker`. Pairs the
/// motion-classifier transition *into* `.cycling` (ride start) with the
/// transition *out* of `.cycling` (ride end). When the ride begins
/// near a known anchor (home/work) AND ends near a known L station,
/// AND we have a fresh MapKit cycling baseline for that anchor → station
/// pair, the ratio becomes a Welford sample on
/// `WalkingDistanceStore.cycleSpeedEstimate`.
///
/// **Restricted to anchor → station rides** because that's the shape
/// of MapKit baseline we already cache. Station → anchor, anchor →
/// anchor, and arbitrary destinations don't have cached cycling
/// baselines today; those rides are silently skipped.
///
/// Same expiry semantics as walks (90 min upper bound), and resolved
/// to landmarks via radius proximity to forgive `lastKnown` staleness
/// at the moment of motion transitions.
///
/// In-memory only; the running stats live on the store. Reset on app
/// launch.
@MainActor
final class BikeSpeedTracker {
    /// Upper bound on plausible bike-commute duration. 90 min covers
    /// leisurely rides + brief stops without letting abandoned rides
    /// silently contaminate the estimate.
    static let pendingExpiry: TimeInterval = 90 * 60

    /// Match radius for resolving the ride's start/end to a landmark.
    /// 250 m forgives GPS drift between the motion-transition moment
    /// and our cached `lastKnown` read.
    static let landmarkMatchRadiusMeters: Double = 250

    private struct PendingRide: Sendable {
        let originAnchor: CommuteAnchors.Anchor
        let startedAt: Date
    }

    private var pendingRide: PendingRide?
    private weak var walkingStore: WalkingDistanceStore?

    init(walkingStore: WalkingDistanceStore?) {
        self.walkingStore = walkingStore
    }

    /// Called when the motion classifier transitions *into* `.cycling`.
    /// Only registers a pending ride if the start location is within
    /// the match radius of a known anchor — otherwise we have no
    /// MapKit baseline to compare against anyway. If a previous pending
    /// ride exists (we missed its end event), it's dropped.
    func recordRideStart(
        at origin: (lat: Double, lon: Double),
        at time: Date,
        anchors: CommuteAnchors
    ) {
        guard let anchor = Self.nearestAnchor(to: origin, anchors: anchors) else {
            pendingRide = nil
            return
        }
        pendingRide = PendingRide(originAnchor: anchor, startedAt: time)
    }

    /// Called when the motion classifier transitions *out* of `.cycling`.
    /// Resolves the destination to the nearest L station within radius
    /// and tries to record a sample. Returns the recorded sample (or
    /// nil if there's no pending ride, the ride expired, no station is
    /// close enough, or no fresh MapKit cycling baseline exists).
    @discardableResult
    func recordRideEnd(
        at destination: (lat: Double, lon: Double),
        at time: Date,
        stations: [LStation] = LStationCatalog.all
    ) -> WalkSpeedSample? {
        guard let ride = pendingRide else { return nil }
        let elapsed = time.timeIntervalSince(ride.startedAt)
        guard elapsed > 0, elapsed <= Self.pendingExpiry else {
            pendingRide = nil
            return nil
        }
        guard let store = walkingStore else {
            pendingRide = nil
            return nil
        }
        guard let station = Self.nearestStation(to: destination, stations: stations) else {
            pendingRide = nil
            return nil
        }

        let origin = (lat: ride.originAnchor.latitude, lon: ride.originAnchor.longitude)
        guard let baseline = store.fresh(
            origin: origin,
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: station.id),
            mode: .cycling
        ) else {
            pendingRide = nil
            return nil
        }

        let sample = WalkSpeedSample(
            actualSeconds: elapsed,
            expectedSeconds: baseline.expectedTravelTime,
            recordedAt: time
        )
        store.recordCycleSpeedSample(sample)
        pendingRide = nil
        return sample
    }

    /// Drop a stale pending ride. Optional sweep — `recordRideEnd`
    /// already applies the expiry check.
    func expireIfStale(now: Date) {
        guard let ride = pendingRide else { return }
        if now.timeIntervalSince(ride.startedAt) > Self.pendingExpiry {
            pendingRide = nil
        }
    }

    // MARK: - Test hooks

    var hasPendingRideForTests: Bool { pendingRide != nil }

    // MARK: - Landmark resolution

    /// Closest anchor within `landmarkMatchRadiusMeters`, or nil. Ties
    /// broken arbitrarily; in practice home and work are far apart.
    static func nearestAnchor(
        to location: (lat: Double, lon: Double),
        anchors: CommuteAnchors
    ) -> CommuteAnchors.Anchor? {
        var best: (anchor: CommuteAnchors.Anchor, distance: Double)?
        let candidates = [anchors.home, anchors.work].compactMap { $0 }
        for anchor in candidates {
            let distance = Distance.meters(
                from: location,
                to: (anchor.latitude, anchor.longitude)
            )
            guard distance <= landmarkMatchRadiusMeters else { continue }
            if let current = best {
                if distance < current.distance { best = (anchor, distance) }
            } else {
                best = (anchor, distance)
            }
        }
        return best?.anchor
    }

    static func nearestStation(
        to location: (lat: Double, lon: Double),
        stations: [LStation]
    ) -> LStation? {
        var best: (station: LStation, distance: Double)?
        for station in stations {
            let distance = Distance.meters(
                from: location,
                to: (station.latitude, station.longitude)
            )
            guard distance <= landmarkMatchRadiusMeters else { continue }
            if let current = best {
                if distance < current.distance { best = (station, distance) }
            } else {
                best = (station, distance)
            }
        }
        return best?.station
    }
}
