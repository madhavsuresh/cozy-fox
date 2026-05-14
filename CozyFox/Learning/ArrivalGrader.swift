import Foundation
import TransitDomain
import TransitModels

/// Phase 2 grader: a passive consumer of every refresh cycle that closes
/// the prediction → reality loop. Pairs each train `Arrival` we display
/// with the eventual `VehiclePosition.nextStopId` transition that resolves
/// it, then writes the `(predicted - observed)` delta into the
/// `ArrivalBiasStore` Welford cells.
///
/// All state is in-memory by design — see the Phase 2 spec. Restarts lose
/// any unresolved trips' grades; the bias store itself is persistent so
/// accumulated samples carry across launches.
///
/// Train-only. Buses (`BusPrediction`) and Metra (`MetraPrediction`) have
/// their own prediction shapes and the matching semantics differ enough
/// that they're a separate problem. The extension point is
/// `ArrivalGradeMatcher.crossings(..., mode:)` — wiring buses or Metra in
/// later only needs a new `ingest...` overload here, not a matcher rewrite.
@MainActor
final class ArrivalGrader {
    /// Active pending grades, keyed by `(line, runNumber, stopId)`. The
    /// **first** prediction received for a key wins — re-ingesting the
    /// same arrival never overwrites `firstPredictedArrivalAt`. This is
    /// load-bearing for the metric: without it, the API trivially looks
    /// accurate because we'd keep updating the prediction as the vehicle
    /// approaches and grade against the most-recent value.
    private var pending: [PendingGradeKey: ArrivalGradeMatcher.PendingGrade] = [:]

    /// Map from `VehiclePosition.id` (run number for trains) to the
    /// previously-observed `nextStopId`. Rebuilt every `ingestPositions`
    /// call. Reset on app launch — Phase 2 is in-memory only.
    private var previousNextStopByRun: [String: Int] = [:]

    /// Wall-clock timestamp of the last snapshot that included each run.
    /// Used to evict stale entries from `previousNextStopByRun` so the
    /// map doesn't grow unbounded over a long-running session.
    private var lastSeenByRun: [String: Date] = [:]

    /// Maximum age before a tracked run is dropped from
    /// `previousNextStopByRun`. 60 minutes is comfortably longer than the
    /// longest run on the L (~90 min for full Red Line end-to-end), so a
    /// run that legitimately disappears from the feed for a few cycles
    /// won't be evicted mid-trip; only runs that have actually completed
    /// service get pruned.
    private static let runTrackTTL: TimeInterval = 60 * 60

    private let matcher = ArrivalGradeMatcher()
    private weak var biasStore: ArrivalBiasStore?
    private let calendar: Calendar

    init(biasStore: ArrivalBiasStore?, calendar: Calendar = .current) {
        self.biasStore = biasStore
        self.calendar = calendar
    }

    // MARK: - Ingest

    /// Register pending grades from a freshly-fetched batch of train
    /// arrivals. A prediction is registered only if it's at least
    /// `minLeadTime` in the future — short-lead-time predictions are
    /// already close enough to the train that they can't be wrong by much
    /// and they crowd out the signal. First-prediction-wins; re-registering
    /// an `(line, runNumber, stopId)` we already track is a no-op.
    func ingestArrivals(
        _ arrivals: [Arrival],
        now: Date = .now,
        minLeadTime: TimeInterval = 3 * 60
    ) async {
        guard !arrivals.isEmpty else { return }
        // Defensive: bootstrap should have already done this. Cheap if
        // already loaded.
        if let biasStore { await biasStore.hydrateFromDiskIfNeeded() }

        for arrival in arrivals {
            guard arrival.arrivalAt.timeIntervalSince(now) >= minLeadTime else { continue }
            let key = PendingGradeKey(
                line: arrival.line.rawValue,
                runNumber: arrival.runNumber,
                stopId: arrival.stopId
            )
            // First-prediction-wins. Leave any existing entry untouched.
            guard pending[key] == nil else { continue }
            pending[key] = ArrivalGradeMatcher.PendingGrade(
                line: arrival.line.rawValue,
                runNumber: arrival.runNumber,
                stopId: arrival.stopId,
                directionCode: arrival.directionCode,
                firstPredictedAt: arrival.predictedAt,
                firstPredictedArrivalAt: arrival.arrivalAt
            )
        }
    }

    /// Ingest a fresh vehicle-position snapshot. Diffs against the prior
    /// snapshot to detect `nextStopId` transitions (= crossings), writes
    /// the resolved deltas into the bias store, and prunes both expired
    /// pending grades and stale runs.
    func ingestPositions(
        _ positions: [VehiclePosition],
        now: Date = .now
    ) async {
        // 1. Compute crossings vs. the previous snapshot.
        let crossings = matcher.crossings(
            previousNextStopByRun: previousNextStopByRun,
            current: positions,
            mode: .train
        )

        // 2. Reconcile and write resolved samples to the bias store.
        let resolutions = matcher.reconcile(crossings: crossings, pending: pending)
        for resolution in resolutions {
            let grade = resolution.pending
            let key = BiasCellKey.make(
                line: grade.line,
                stopId: String(grade.stopId),
                direction: grade.directionCode,
                at: grade.firstPredictedArrivalAt,
                calendar: calendar
            )
            biasStore?.recordSample(
                key: key,
                deltaSeconds: resolution.deltaSeconds,
                at: resolution.observedCrossingAt
            )
            pending.removeValue(
                forKey: PendingGradeKey(
                    line: grade.line,
                    runNumber: grade.runNumber,
                    stopId: grade.stopId
                )
            )
        }

        // 3. Refresh `previousNextStopByRun` and `lastSeenByRun` from the
        // current snapshot. Train-only; non-train modes are ignored so a
        // bus showing up in the same snapshot doesn't crowd the map.
        for position in positions where position.mode == .train {
            lastSeenByRun[position.id] = position.observedAt
            if let nextStop = position.nextStopId {
                previousNextStopByRun[position.id] = nextStop
            }
        }

        // 4. Prune runs that haven't been seen in a while. Walk the
        // last-seen map and drop both entries together.
        let runTTLCutoff = now.addingTimeInterval(-Self.runTrackTTL)
        var staleRuns: [String] = []
        for (run, lastSeen) in lastSeenByRun where lastSeen < runTTLCutoff {
            staleRuns.append(run)
        }
        for run in staleRuns {
            lastSeenByRun.removeValue(forKey: run)
            previousNextStopByRun.removeValue(forKey: run)
        }

        // 5. Drop expired pending grades (>30 min past their predicted
        // arrival with no resolution). Silent discard — Phase 2 doesn't
        // emit negative samples for unfulfilled predictions.
        let expired = matcher.expiredKeys(in: pending, now: now)
        for key in expired {
            pending.removeValue(forKey: key)
        }
    }

    // MARK: - Test hooks

    /// Test-only: the size of the pending-grade map.
    var pendingCountForTests: Int { pending.count }

    /// Test-only: look up a pending grade by its component identity.
    func _pendingForTests(
        line: String,
        runNumber: String,
        stopId: Int
    ) -> ArrivalGradeMatcher.PendingGrade? {
        pending[PendingGradeKey(line: line, runNumber: runNumber, stopId: stopId)]
    }

    /// Test-only: the size of the previous-next-stop map (used to verify
    /// run-track pruning).
    var trackedRunCountForTests: Int { previousNextStopByRun.count }
}
