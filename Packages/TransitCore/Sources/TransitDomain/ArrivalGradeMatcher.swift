import Foundation
import TransitModels

/// Pure, side-effect-free reconciliation between train *predictions* we
/// displayed and the *actual* `VehiclePosition` crossings the agency feed
/// later reported. Reads only the inputs the caller hands it; holds no
/// state. The orchestrator (`ArrivalGrader`) owns the pending map and the
/// previous-snapshot map and feeds them in.
///
/// Algorithm in three pieces:
///   1. `crossings(...)` diffs the previous-snapshot's `nextStopId`-by-run
///      against the current snapshot. For each run whose `nextStopId`
///      changed from S₁ to S₂, the train has just rolled past S₁ — emit a
///      crossing for the *previous* stop. Snapshot gaps that skip a stop
///      degrade gracefully to "the last stop we knew about." Phase 2 trades
///      off skipped-stop visibility for simplicity; geometric inference is
///      a deliberately deferred enhancement.
///   2. `reconcile(...)` does dictionary lookups against the pending grade
///      map to produce ready-to-write `Resolution` records. Multiple
///      pending grades can share a `(line, runNumber)` if they target
///      different stops — the key carries `stopId` for exactly this reason.
///   3. `expiredKeys(...)` reports pending grades the matcher considers
///      lost (`firstPredictedArrivalAt` ≥ 30 min stale). The caller drops
///      them silently — Phase 2 doesn't write negative samples for "we
///      never saw the train cross."
public struct ArrivalGradeMatcher: Sendable {
    public struct PendingGrade: Sendable, Hashable {
        /// `LineColor.rawValue` for trains. Kept as a `String` so future
        /// extensions (buses, Metra) can reuse the same shape without
        /// import-cycling on the line enum.
        public let line: String
        public let runNumber: String
        public let stopId: Int
        public let directionCode: String
        /// When we first *displayed* this prediction. Useful for diagnostics
        /// (Phase 3+ may want to know how stale the original was).
        public let firstPredictedAt: Date
        /// When the original prediction said the train would arrive at
        /// `stopId`. Used both as the math anchor for `deltaSeconds` and as
        /// the timestamp passed to `BiasCellKey.make(at:)` so the bucket
        /// reflects when the train was *supposed* to be there, not when we
        /// resolved the grade.
        public let firstPredictedArrivalAt: Date

        public init(
            line: String,
            runNumber: String,
            stopId: Int,
            directionCode: String,
            firstPredictedAt: Date,
            firstPredictedArrivalAt: Date
        ) {
            self.line = line
            self.runNumber = runNumber
            self.stopId = stopId
            self.directionCode = directionCode
            self.firstPredictedAt = firstPredictedAt
            self.firstPredictedArrivalAt = firstPredictedArrivalAt
        }
    }

    /// A resolved crossing ready to be written to `ArrivalBiasStore`.
    /// `deltaSeconds = observedCrossingAt - firstPredictedArrivalAt`.
    /// Positive ⇒ vehicle arrived *later* than predicted ⇒ "API was early /
    /// vehicle late," matching `BiasCell`'s documented convention (see
    /// `BiasCellTests.decayHalvesCountAtOneHalfLife`, where positive
    /// samples are labeled "API early").
    public struct Resolution: Sendable, Hashable {
        public let pending: PendingGrade
        public let observedCrossingAt: Date
        public let deltaSeconds: Double

        public init(
            pending: PendingGrade,
            observedCrossingAt: Date,
            deltaSeconds: Double
        ) {
            self.pending = pending
            self.observedCrossingAt = observedCrossingAt
            self.deltaSeconds = deltaSeconds
        }
    }

    public init() {}

    /// One-pass diff of two position snapshots. Returns each run whose
    /// `nextStopId` changed since the previous snapshot, paired with the
    /// *previous* `nextStopId` (the stop the train just rolled past) and
    /// the *current* snapshot's `observedAt` (best approximation of the
    /// crossing moment without higher-frequency sampling — accepted as
    /// Phase-2 minimum-viable).
    ///
    /// Vehicles whose `mode` doesn't match `mode` are skipped — Phase 2 is
    /// train-only. Vehicles whose `nextStopId` is `nil` in the current
    /// snapshot are also skipped (the train ran off the end of the line or
    /// the feed dropped the field — either way we can't confirm a
    /// crossing).
    public func crossings(
        previousNextStopByRun: [String: Int],
        current: [VehiclePosition],
        mode: VehiclePosition.Mode = .train
    ) -> [(runNumber: String, route: String, crossedStopId: Int, observedAt: Date)] {
        var crossings: [(runNumber: String, route: String, crossedStopId: Int, observedAt: Date)] = []
        crossings.reserveCapacity(current.count)
        for position in current {
            guard position.mode == mode else { continue }
            guard let currentNext = position.nextStopId else { continue }
            guard let previousNext = previousNextStopByRun[position.id] else { continue }
            guard previousNext != currentNext else { continue }
            crossings.append((
                runNumber: position.id,
                route: position.route,
                crossedStopId: previousNext,
                observedAt: position.observedAt
            ))
        }
        return crossings
    }

    /// Match each crossing against the pending-grade map. Crossings whose
    /// `(line, runNumber, stopId)` triple isn't in `pending` are silently
    /// dropped — this is normal. The orchestrator only registers pending
    /// grades for predictions it actually displayed, so most crossings
    /// (other lines, other stops on the same line we don't care about)
    /// pass through unmatched.
    public func reconcile(
        crossings: [(runNumber: String, route: String, crossedStopId: Int, observedAt: Date)],
        pending: [PendingGradeKey: PendingGrade]
    ) -> [Resolution] {
        var resolutions: [Resolution] = []
        resolutions.reserveCapacity(crossings.count)
        for crossing in crossings {
            let key = PendingGradeKey(
                line: crossing.route,
                runNumber: crossing.runNumber,
                stopId: crossing.crossedStopId
            )
            guard let pendingGrade = pending[key] else { continue }
            let delta = crossing.observedAt.timeIntervalSince(pendingGrade.firstPredictedArrivalAt)
            resolutions.append(
                Resolution(
                    pending: pendingGrade,
                    observedCrossingAt: crossing.observedAt,
                    deltaSeconds: delta
                )
            )
        }
        return resolutions
    }

    /// Returns the pending grade keys whose `firstPredictedArrivalAt` is
    /// more than `maxAge` in the past — i.e. predictions the matcher never
    /// got to confirm. The caller drops these silently.
    public func expiredKeys(
        in pending: [PendingGradeKey: PendingGrade],
        now: Date,
        maxAge: TimeInterval = 30 * 60
    ) -> [PendingGradeKey] {
        var expired: [PendingGradeKey] = []
        expired.reserveCapacity(pending.count)
        for (key, grade) in pending {
            if now.timeIntervalSince(grade.firstPredictedArrivalAt) > maxAge {
                expired.append(key)
            }
        }
        return expired
    }
}

/// Identity for a pending grade. `(line, runNumber, stopId)` is unique:
/// the same run can have multiple pending grades when the user is watching
/// several stops on its path, and different lines can share a run number
/// (CTA reuses them across services).
public struct PendingGradeKey: Hashable, Sendable {
    public let line: String
    public let runNumber: String
    public let stopId: Int

    public init(line: String, runNumber: String, stopId: Int) {
        self.line = line
        self.runNumber = runNumber
        self.stopId = stopId
    }
}
