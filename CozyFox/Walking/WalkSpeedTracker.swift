import Foundation
import TransitDomain
import TransitModels

/// Stopwatch state machine for Phase 5. Pairs `LocationCoordinator
/// .onRegionExit` (start) with `BoardingDetector` boarding events (end)
/// to measure how long the user actually walks from home/work to an L
/// station, then compares to MapKit's cached `expectedTravelTime` and
/// feeds the per-user `WalkSpeedEstimate` on `WalkingDistanceStore`.
///
/// In-memory only; the running mean lives on the store. Reset on app
/// launch, which is fine — pending walks expire fast (≤45 min) and
/// `onRegionExit` re-fires whenever the user actually exits a region.
///
/// `pendingExpiry` covers a comfortable upper bound on plausible
/// commute walks; a longer "exit" without a boarding is treated as the
/// user doing something else.
@MainActor
final class WalkSpeedTracker {
    static let pendingExpiry: TimeInterval = 45 * 60

    private struct PendingWalk: Sendable {
        let direction: CommuteDirection
        let anchor: CommuteAnchors.Anchor
        let startedAt: Date
    }

    private var pendingWalk: PendingWalk?
    private weak var walkingStore: WalkingDistanceStore?

    init(walkingStore: WalkingDistanceStore?) {
        self.walkingStore = walkingStore
    }

    /// Call from the `LocationCoordinator.onRegionExit` fan-out. The
    /// most recent exit wins — if the user re-entered and exited a
    /// region twice before boarding, we want the second timestamp.
    func recordRegionExit(direction: CommuteDirection, anchor: CommuteAnchors.Anchor, at: Date) {
        pendingWalk = PendingWalk(direction: direction, anchor: anchor, startedAt: at)
    }

    /// Call from the `BoardingDetector` hook in `RefreshCoordinator`.
    /// Returns the recorded sample (or nil if no pending walk, the
    /// pending walk expired, or no fresh MapKit baseline). The sample is
    /// already submitted to the store before this returns — the return
    /// value is for tests + diagnostics.
    @discardableResult
    func recordBoarding(stationId: Int, at: Date) -> WalkSpeedSample? {
        guard let walk = pendingWalk else { return nil }
        let elapsed = at.timeIntervalSince(walk.startedAt)
        guard elapsed > 0, elapsed <= Self.pendingExpiry else {
            pendingWalk = nil
            return nil
        }
        guard let store = walkingStore else {
            pendingWalk = nil
            return nil
        }
        // Fresh cached baseline only — stale / missing means we don't
        // have a reliable comparison and silently skip rather than
        // record a noisy sample.
        guard let baseline = store.fresh(
            origin: (lat: walk.anchor.latitude, lon: walk.anchor.longitude),
            stationId: stationId
        ) else {
            pendingWalk = nil
            return nil
        }
        let sample = WalkSpeedSample(
            actualSeconds: elapsed,
            expectedSeconds: baseline.expectedTravelTime,
            recordedAt: at
        )
        store.recordWalkSpeedSample(sample)
        pendingWalk = nil
        return sample
    }

    /// Drop a stale pending walk. Optional — `recordBoarding` already
    /// applies the expiry check, but exposing this lets callers (or
    /// tests) sweep without needing a boarding event.
    func expireIfStale(now: Date) {
        guard let walk = pendingWalk else { return }
        if now.timeIntervalSince(walk.startedAt) > Self.pendingExpiry {
            pendingWalk = nil
        }
    }

    // MARK: - Test hooks
    var hasPendingWalkForTests: Bool { pendingWalk != nil }
}
