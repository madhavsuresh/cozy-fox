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
/// Trains + buses. Metra has the same `ArrivalGradeMatcher` extension
/// point (`crossings(..., mode: .metra)`) but its `VehiclePosition`
/// `nextStopId` is `current_stop_sequence` rather than a stop id, so
/// passive resolution doesn't work without a separate trip-sequence
/// index. Metra grading is deferred to a follow-up.
@MainActor
final class ArrivalGrader {
    /// Active pending grades, keyed by `(line, runNumber, stopId)`. The
    /// **first** prediction received for a key wins — re-ingesting the
    /// same arrival never overwrites `firstPredictedArrivalAt`. This is
    /// load-bearing for the metric: without it, the API trivially looks
    /// accurate because we'd keep updating the prediction as the vehicle
    /// approaches and grade against the most-recent value.
    private var pending: [PendingGradeKey: ArrivalGradeMatcher.PendingGrade] = [:]

    /// Map from `VehiclePosition.id` (run number for trains, vehicle id
    /// for buses) to the previously-observed `nextStopId`. Split by mode
    /// so a bus vehicle id can't shadow a train run number that happens
    /// to share the same digits — they live in independent id spaces.
    /// Reset on app launch.
    private var previousNextStopByTrainRun: [String: Int] = [:]
    private var previousNextStopByBusVehicle: [String: Int] = [:]

    /// Map from `Arrival.stopId` (per-platform) to `Arrival.stationId`
    /// (per-station). Phase 4 boarding events arrive at the station
    /// granularity (`LStation.id` via `BoardingDetector`), but the
    /// pending-grade map is keyed by platform-level `stopId`. Each
    /// `ingestArrivals` call populates this from the `Arrival` payloads
    /// themselves — `Arrival` carries both fields, so we never need a
    /// separate `LStationCatalog` index. Reset on app launch.
    private var stationIdByStopId: [Int: Int] = [:]

    /// Wall-clock timestamp of the last snapshot that included each
    /// tracked run/vehicle. Used to evict stale entries from
    /// `previousNextStop*` so the maps don't grow unbounded.
    private var lastSeenByTrainRun: [String: Date] = [:]
    private var lastSeenByBusVehicle: [String: Date] = [:]

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
    /// Phase 4 hook: when a *bus* arrival resolves, the grader builds a
    /// `BusPredictionResidual` from `Resolution.deltaSeconds` + the
    /// pending grade and hands it to this closure. The app wires it to
    /// `TransitStore.recordBusResidual`; tests can substitute a capture
    /// closure. Train resolutions don't fire this — the residual store
    /// is intentionally bus-only because that's where calibration buys
    /// the most ground (CTA train predictions are already much tighter).
    private let residualRecorder: (@MainActor (BusPredictionResidual) -> Void)?

    init(
        biasStore: ArrivalBiasStore?,
        calendar: Calendar = .current,
        residualRecorder: (@MainActor (BusPredictionResidual) -> Void)? = nil
    ) {
        self.biasStore = biasStore
        self.calendar = calendar
        self.residualRecorder = residualRecorder
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
            // Cache the platform → station mapping unconditionally, so
            // Phase 4 boarding events can resolve pending grades by
            // station even when individual arrivals were skipped by
            // the lead-time gate.
            stationIdByStopId[arrival.stopId] = arrival.stationId
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

    /// Register pending grades from a freshly-fetched batch of bus
    /// predictions. Same shape as `ingestArrivals` but keyed by
    /// `(route, vehicleId, stopId)`. Buses don't have a "run number"
    /// concept — `vehicleId` is its functional analog (the bus assigned
    /// to that pull at that stop). `directionName` becomes the cell key's
    /// direction component.
    func ingestBusPredictions(
        _ predictions: [BusPrediction],
        now: Date = .now,
        minLeadTime: TimeInterval = 3 * 60
    ) async {
        guard !predictions.isEmpty else { return }
        if let biasStore { await biasStore.hydrateFromDiskIfNeeded() }

        for prediction in predictions {
            guard prediction.arrivalAt.timeIntervalSince(now) >= minLeadTime else { continue }
            let key = PendingGradeKey(
                line: prediction.route,
                runNumber: prediction.vehicleId,
                stopId: prediction.stopId
            )
            guard pending[key] == nil else { continue }
            pending[key] = ArrivalGradeMatcher.PendingGrade(
                line: prediction.route,
                runNumber: prediction.vehicleId,
                stopId: prediction.stopId,
                directionCode: prediction.directionName,
                firstPredictedAt: prediction.generatedAt,
                firstPredictedArrivalAt: prediction.arrivalAt
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
        // 1. Compute crossings vs. the previous snapshot. Trains and
        // buses both use the same `nextStopId`-transition heuristic
        // (`nextStopId` for buses is the upcoming stop id reported by
        // the bus tracker). Metra excluded — its `nextStopId` is a
        // stop sequence index, not a stop id, and would falsely match.
        let trainCrossings = matcher.crossings(
            previousNextStopByRun: previousNextStopByTrainRun,
            current: positions,
            mode: .train
        )
        let busCrossings = matcher.crossings(
            previousNextStopByRun: previousNextStopByBusVehicle,
            current: positions,
            mode: .bus
        )

        // 2. Reconcile and write resolved samples to the bias store.
        let resolutions = matcher.reconcile(
            crossings: trainCrossings + busCrossings,
            pending: pending
        )
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
            // Phase 4: write a bus-only residual to the calibration
            // store. `grade.line` is the route number for buses; for
            // trains it's a `LineColor` raw value. Only fire when the
            // line is *not* a known train color.
            if let recorder = residualRecorder,
               LineColor(rawValue: grade.line) == nil,
               let stopIdInt = Int(exactly: grade.stopId) {
                let horizonSeconds = grade.firstPredictedArrivalAt.timeIntervalSince(grade.firstPredictedAt)
                let bucket = BusHorizonBucket.bucket(for: horizonSeconds)
                let hourOfWeek = BusHourOfWeek.value(
                    for: grade.firstPredictedArrivalAt,
                    calendar: calendar
                )
                let residual = BusPredictionResidual(
                    route: grade.line,
                    directionName: grade.directionCode,
                    stopId: stopIdInt,
                    vehicleId: grade.runNumber,
                    predictedAt: grade.firstPredictedAt,
                    predictedArrivalAt: grade.firstPredictedArrivalAt,
                    confirmedArrivalAt: resolution.observedCrossingAt,
                    horizonBucket: bucket,
                    hourOfWeek: hourOfWeek,
                    residualSeconds: resolution.deltaSeconds
                )
                recorder(residual)
            }
            pending.removeValue(
                forKey: PendingGradeKey(
                    line: grade.line,
                    runNumber: grade.runNumber,
                    stopId: grade.stopId
                )
            )
        }

        // 3. Refresh the previous-snapshot + last-seen maps. Train +
        // bus only; Metra positions are skipped because their
        // `nextStopId` semantics don't match. Mode-split so a bus
        // vehicle id can't overwrite a train run's entry.
        for position in positions {
            switch position.mode {
            case .train:
                lastSeenByTrainRun[position.id] = position.observedAt
                if let nextStop = position.nextStopId {
                    previousNextStopByTrainRun[position.id] = nextStop
                }
            case .bus:
                lastSeenByBusVehicle[position.id] = position.observedAt
                if let nextStop = position.nextStopId {
                    previousNextStopByBusVehicle[position.id] = nextStop
                }
            case .metra:
                break
            }
        }

        // 4. Prune runs/vehicles that haven't been seen in a while.
        let runTTLCutoff = now.addingTimeInterval(-Self.runTrackTTL)
        let staleTrains = lastSeenByTrainRun.filter { $0.value < runTTLCutoff }.map(\.key)
        for run in staleTrains {
            lastSeenByTrainRun.removeValue(forKey: run)
            previousNextStopByTrainRun.removeValue(forKey: run)
        }
        let staleBuses = lastSeenByBusVehicle.filter { $0.value < runTTLCutoff }.map(\.key)
        for vehicle in staleBuses {
            lastSeenByBusVehicle.removeValue(forKey: vehicle)
            previousNextStopByBusVehicle.removeValue(forKey: vehicle)
        }

        // 5. Drop expired pending grades (>30 min past their predicted
        // arrival with no resolution). Silent discard — Phase 2 doesn't
        // emit negative samples for unfulfilled predictions.
        let expired = matcher.expiredKeys(in: pending, now: now)
        for key in expired {
            pending.removeValue(forKey: key)
        }
    }

    /// Phase 4: resolve pending grades at a station using the user's
    /// actual boarding moment as ground truth. Higher-quality than
    /// `VehiclePosition.nextStopId` transitions for two reasons:
    ///   1. **Subway / tunnel coverage**: at subway stops the
    ///      `nextStopId` field can be sparse or missing; passive grading
    ///      misses those crossings entirely. A user being there closes
    ///      the loop.
    ///   2. **Door-open moment**: the boarding event captures when the
    ///      user could actually board, not when the GTFS-rt feed says
    ///      the vehicle crossed a sensor — a small but consistent
    ///      offset.
    ///
    /// For each pending grade whose `stopId` maps to `stationId` and
    /// whose `firstPredictedArrivalAt` falls within `±matchWindow` of
    /// `observedAt`, this writes a Welford sample with
    /// `deltaSeconds = observedAt - firstPredictedArrivalAt` (same sign
    /// convention as passive grading) and removes the entry from
    /// `pending`. Multiple lines at the same station predicting around
    /// the same time each get their own sample.
    ///
    /// **No double-write**: the entry is removed from `pending` as part
    /// of this method; a later `nextStopId` transition for the same key
    /// will find nothing to resolve.
    ///
    /// **Sample weight stays equal** to passive samples. Welford running
    /// stats don't take a per-sample weight; the value here is coverage,
    /// not weight inflation.
    ///
    /// Returns the number of pending grades resolved — useful for tests.
    @discardableResult
    func ingestBoardingEvent(
        stationId: Int,
        observedAt: Date,
        matchWindow: TimeInterval = 3 * 60
    ) async -> Int {
        if let biasStore { await biasStore.hydrateFromDiskIfNeeded() }

        var matchedKeys: [PendingGradeKey] = []
        matchedKeys.reserveCapacity(pending.count)
        for (key, grade) in pending {
            guard let mappedStationId = stationIdByStopId[grade.stopId] else { continue }
            guard mappedStationId == stationId else { continue }
            let delta = abs(observedAt.timeIntervalSince(grade.firstPredictedArrivalAt))
            guard delta <= matchWindow else { continue }
            matchedKeys.append(key)
        }

        for key in matchedKeys {
            guard let grade = pending[key] else { continue }
            let cellKey = BiasCellKey.make(
                line: grade.line,
                stopId: String(grade.stopId),
                direction: grade.directionCode,
                at: grade.firstPredictedArrivalAt,
                calendar: calendar
            )
            let deltaSeconds = observedAt.timeIntervalSince(grade.firstPredictedArrivalAt)
            biasStore?.recordSample(
                key: cellKey,
                deltaSeconds: deltaSeconds,
                at: observedAt
            )
            pending.removeValue(forKey: key)
        }

        return matchedKeys.count
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

    /// Test-only: the size of the train previous-next-stop map (used to
    /// verify run-track pruning). Bus variant available via
    /// `trackedBusVehicleCountForTests`.
    var trackedRunCountForTests: Int { previousNextStopByTrainRun.count }

    var trackedBusVehicleCountForTests: Int { previousNextStopByBusVehicle.count }
}
