import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("ArrivalGradeMatcher")
struct ArrivalGradeMatcherTests {
    private let matcher = ArrivalGradeMatcher()
    private let t0 = Date(timeIntervalSinceReferenceDate: 770_000_000)

    private func position(
        id: String,
        route: String = "red",
        nextStopId: Int?,
        observedAt: Date,
        mode: VehiclePosition.Mode = .train
    ) -> VehiclePosition {
        VehiclePosition(
            id: id,
            mode: mode,
            route: route,
            latitude: 41.0,
            longitude: -87.0,
            nextStopId: nextStopId,
            observedAt: observedAt
        )
    }

    // MARK: - crossings(...)

    @Test func transitionEmitsCrossingForPreviousStop() {
        let previous = ["401": 30173]
        let current = [position(id: "401", nextStopId: 30174, observedAt: t0)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.count == 1)
        #expect(crossings.first?.runNumber == "401")
        #expect(crossings.first?.crossedStopId == 30173)
        #expect(crossings.first?.observedAt == t0)
    }

    @Test func snapshotGapPicksMostRecentlyKnownPreviousStop() {
        // R was heading to S₁ (30173). Two snapshots later it's heading to
        // S₃ (30175), skipping S₂ (30174). Phase 2 emits one crossing for
        // S₁ — we don't fabricate a crossing for the skipped stop because
        // we never observed the train pointed at it. Documented tradeoff.
        let previous = ["401": 30173]
        let current = [position(id: "401", nextStopId: 30175, observedAt: t0)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.count == 1)
        #expect(crossings.first?.crossedStopId == 30173)
    }

    @Test func runDropsOutOfSnapshotEmitsNothing() {
        // R was tracked. Current snapshot doesn't include it (out of agency
        // view temporarily). No crossing — the pending stays in pending.
        let previous = ["401": 30173]
        let current: [VehiclePosition] = []
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.isEmpty)
    }

    @Test func runReappearsWithSameNextStopIdEmitsNothing() {
        let previous = ["401": 30173]
        let current = [position(id: "401", nextStopId: 30173, observedAt: t0)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.isEmpty)
    }

    @Test func unknownRunEmitsNothing() {
        // Run wasn't in the previous snapshot — we have no baseline so
        // can't infer a crossing.
        let previous: [String: Int] = [:]
        let current = [position(id: "401", nextStopId: 30173, observedAt: t0)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.isEmpty)
    }

    @Test func nilNextStopIdInCurrentIsSkipped() {
        let previous = ["401": 30173]
        let current = [position(id: "401", nextStopId: nil, observedAt: t0)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.isEmpty)
    }

    @Test func nonMatchingModeIsSkipped() {
        // Bus in train-mode call: skipped. We never want to grade a bus
        // against a train pending grade.
        let previous = ["bus-1841": 4000]
        let current = [position(id: "bus-1841", route: "22", nextStopId: 4001, observedAt: t0, mode: .bus)]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current,
            mode: .train
        )
        #expect(crossings.isEmpty)
    }

    @Test func multipleRunsEmitIndependentCrossings() {
        let previous = ["401": 30173, "402": 30200, "403": 30300]
        let current = [
            position(id: "401", nextStopId: 30174, observedAt: t0),
            position(id: "402", nextStopId: 30200, observedAt: t0), // no change
            position(id: "403", nextStopId: 30301, observedAt: t0),
        ]
        let crossings = matcher.crossings(
            previousNextStopByRun: previous,
            current: current
        )
        #expect(crossings.count == 2)
        let crossed = Set(crossings.map(\.crossedStopId))
        #expect(crossed == [30173, 30300])
    }

    // MARK: - reconcile(...)

    @Test func reconcileMatchesAndComputesPositiveDeltaForLateVehicle() {
        // Predicted arrival at t0+5min; vehicle actually crossed at
        // t0+7min ⇒ vehicle was 2 minutes late. Per BiasCell's convention
        // (positive = API early / vehicle late) this should be POSITIVE.
        let predictedAt = t0
        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let observed = t0.addingTimeInterval(7 * 60)

        let pending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: predictedAt,
            firstPredictedArrivalAt: predictedArrivalAt
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)

        let crossings = [(
            runNumber: "401",
            route: "red",
            crossedStopId: 30173,
            observedAt: observed
        )]

        let resolutions = matcher.reconcile(
            crossings: crossings,
            pending: [key: pending]
        )
        #expect(resolutions.count == 1)
        let resolution = resolutions[0]
        #expect(resolution.pending == pending)
        #expect(resolution.observedCrossingAt == observed)
        // Sign assertion: vehicle 2 minutes late ⇒ +120 seconds.
        // Per `BiasCellTests` line 47 ("positive ⇒ API early"), a delta
        // that's POSITIVE means the API was early — i.e. the train was
        // later than predicted. This is the contract Phase 2 writes into.
        #expect(resolution.deltaSeconds == 120)
    }

    @Test func reconcileNegativeDeltaForEarlyVehicle() {
        // Vehicle 90s earlier than predicted ⇒ delta = -90 (API late /
        // vehicle early).
        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let observed = t0.addingTimeInterval(5 * 60 - 90)
        let pending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: predictedArrivalAt
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)
        let crossings = [(
            runNumber: "401",
            route: "red",
            crossedStopId: 30173,
            observedAt: observed
        )]
        let resolutions = matcher.reconcile(
            crossings: crossings,
            pending: [key: pending]
        )
        #expect(resolutions.count == 1)
        #expect(resolutions[0].deltaSeconds == -90)
    }

    @Test func reconcileSilentlyDropsUnknownCrossings() {
        // Crossing exists but no matching pending entry: ignored.
        let crossings = [(
            runNumber: "999",
            route: "blue",
            crossedStopId: 40380,
            observedAt: t0
        )]
        let resolutions = matcher.reconcile(crossings: crossings, pending: [:])
        #expect(resolutions.isEmpty)
    }

    @Test func reconcileMatchesOnLineRouteAndStopIdTuple() {
        // Two pending grades with same runNumber but different stops on
        // the same line: each resolves only against its own crossing.
        let pendingA = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0.addingTimeInterval(120)
        )
        let pendingB = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30200,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0.addingTimeInterval(360)
        )
        let pending = [
            PendingGradeKey(line: "red", runNumber: "401", stopId: 30173): pendingA,
            PendingGradeKey(line: "red", runNumber: "401", stopId: 30200): pendingB,
        ]
        let crossings = [
            (runNumber: "401", route: "red", crossedStopId: 30173, observedAt: t0.addingTimeInterval(180))
        ]
        let resolutions = matcher.reconcile(crossings: crossings, pending: pending)
        #expect(resolutions.count == 1)
        #expect(resolutions[0].pending == pendingA)
    }

    @Test func reconcileLineCollisionAcrossModesDoesNotMatch() {
        // A pending grade for line "red" should NOT match a crossing for
        // route "22" (bus route) even if they happen to share runNumber
        // and stopId. The line/route discriminator is what isolates them.
        let pending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0.addingTimeInterval(120)
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)
        let crossings = [(
            runNumber: "401",
            route: "22",
            crossedStopId: 30173,
            observedAt: t0
        )]
        let resolutions = matcher.reconcile(
            crossings: crossings,
            pending: [key: pending]
        )
        #expect(resolutions.isEmpty)
    }

    // MARK: - expiredKeys(...)

    @Test func expiredKeysReportsGradeOlderThan30Min() {
        let oldPending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)
        let expired = matcher.expiredKeys(
            in: [key: oldPending],
            now: t0.addingTimeInterval(31 * 60)
        )
        #expect(expired == [key])
    }

    @Test func expiredKeysIgnoresGradeYoungerThan30Min() {
        let recentPending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)
        let expired = matcher.expiredKeys(
            in: [key: recentPending],
            now: t0.addingTimeInterval(29 * 60)
        )
        #expect(expired.isEmpty)
    }

    @Test func expiredKeysEmptyForEmptyInput() {
        let expired = matcher.expiredKeys(in: [:], now: t0)
        #expect(expired.isEmpty)
    }

    @Test func expiredKeysRespectsCustomMaxAge() {
        let pending = ArrivalGradeMatcher.PendingGrade(
            line: "red",
            runNumber: "401",
            stopId: 30173,
            directionCode: "1",
            firstPredictedAt: t0,
            firstPredictedArrivalAt: t0
        )
        let key = PendingGradeKey(line: "red", runNumber: "401", stopId: 30173)
        // 6 minutes old, custom maxAge of 5 minutes ⇒ expired.
        let expired = matcher.expiredKeys(
            in: [key: pending],
            now: t0.addingTimeInterval(6 * 60),
            maxAge: 5 * 60
        )
        #expect(expired == [key])
    }

    @Test func isSendableAndCallableOffMain() async {
        let previous = ["401": 30173]
        let current = [position(id: "401", nextStopId: 30174, observedAt: t0)]
        let result = await Task.detached { [previous, current] in
            ArrivalGradeMatcher().crossings(
                previousNextStopByRun: previous,
                current: current
            )
        }.value
        #expect(result.count == 1)
        #expect(result.first?.crossedStopId == 30173)
    }
}
