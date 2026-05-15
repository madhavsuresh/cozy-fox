import Foundation
import Testing
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("ArrivalGrader")
struct ArrivalGraderTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 770_000_000)

    private func makeArrival(
        line: LineColor = .red,
        runNumber: String = "401",
        stopId: Int = 30173,
        directionCode: String = "1",
        predictedAt: Date,
        arrivalAt: Date
    ) -> Arrival {
        Arrival(
            id: "\(runNumber)-\(stopId)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            line: line,
            runNumber: runNumber,
            destinationName: "Howard",
            stationId: 40900,
            stationName: "Howard",
            stopId: stopId,
            directionCode: directionCode,
            predictedAt: predictedAt,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private func makePosition(
        runNumber: String = "401",
        route: String = "red",
        nextStopId: Int?,
        observedAt: Date,
        mode: VehiclePosition.Mode = .train
    ) -> VehiclePosition {
        VehiclePosition(
            id: runNumber,
            mode: mode,
            route: route,
            latitude: 41.0,
            longitude: -87.0,
            nextStopId: nextStopId,
            observedAt: observedAt
        )
    }

    // MARK: - ingestArrivals

    @Test func ingestSkipsPredictionsInsideLeadTimeWindow() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-leadtime"))
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        // 2 minutes out — under the 3-min default lead time. Should NOT
        // be registered.
        let tooClose = makeArrival(
            predictedAt: t0,
            arrivalAt: t0.addingTimeInterval(2 * 60)
        )
        // 5 minutes out — passes the gate.
        let okPrediction = makeArrival(
            runNumber: "402",
            stopId: 30200,
            predictedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        await grader.ingestArrivals([tooClose, okPrediction], now: t0)

        #expect(grader.pendingCountForTests == 1)
        #expect(grader._pendingForTests(line: "red", runNumber: "402", stopId: 30200) != nil)
        #expect(grader._pendingForTests(line: "red", runNumber: "401", stopId: 30173) == nil)
    }

    @Test func ingestIsIdempotentAndKeepsFirstPredictedArrivalAt() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-idempotent"))
        let grader = ArrivalGrader(biasStore: store)

        // First sighting: train predicted to arrive at t0+5m.
        let first = makeArrival(
            predictedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        await grader.ingestArrivals([first], now: t0)

        // Later reprediction: same (line, runNumber, stopId) but now the
        // API says it arrives at t0+8m (= 3 minutes later). The grader
        // must NOT overwrite the original prediction — first wins.
        let later = makeArrival(
            predictedAt: t0.addingTimeInterval(60),
            arrivalAt: t0.addingTimeInterval(8 * 60)
        )
        await grader.ingestArrivals([later], now: t0.addingTimeInterval(60))

        #expect(grader.pendingCountForTests == 1)
        let stored = grader._pendingForTests(line: "red", runNumber: "401", stopId: 30173)
        #expect(stored?.firstPredictedArrivalAt == t0.addingTimeInterval(5 * 60))
        #expect(stored?.firstPredictedAt == t0)
    }

    // MARK: - ingestPositions resolution

    @Test func resolutionWritesSampleWithCorrectSign() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-resolve"))
        await store.hydrateFromDiskIfNeeded()
        // Chicago calendar so the bias-cell time-of-day buckets are
        // deterministic across CI hosts.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let grader = ArrivalGrader(biasStore: store, calendar: calendar)

        // Pin the predicted-arrival time to a known wall clock so the
        // BiasCellKey we expect is reproducible.
        let predictedArrivalAt = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026, month: 5, day: 14, hour: 8, minute: 30
        ))!
        let predictedAt = predictedArrivalAt.addingTimeInterval(-5 * 60)

        let arrival = makeArrival(
            predictedAt: predictedAt,
            arrivalAt: predictedArrivalAt
        )
        // Ingest "now" must be at least 3 minutes before arrivalAt so the
        // lead-time gate lets the pending entry register.
        await grader.ingestArrivals([arrival], now: predictedAt)

        // First positions snapshot: train heading to our stop. Seeds the
        // previousNextStopByRun map — no crossings yet.
        let firstSnapshot = makePosition(
            nextStopId: 30173,
            observedAt: predictedArrivalAt.addingTimeInterval(-60)
        )
        await grader.ingestPositions([firstSnapshot], now: predictedArrivalAt.addingTimeInterval(-60))
        #expect(grader.pendingCountForTests == 1)

        // Second snapshot: train now heading to the next stop. The
        // transition resolves our pending grade. Observed at +90s vs
        // predicted ⇒ deltaSeconds = +90.
        let observedAt = predictedArrivalAt.addingTimeInterval(90)
        let secondSnapshot = makePosition(
            nextStopId: 30174,
            observedAt: observedAt
        )
        await grader.ingestPositions([secondSnapshot], now: observedAt)

        // Pending should now be empty.
        #expect(grader.pendingCountForTests == 0)

        // Bias store should have one cell with mean +90s.
        let expectedKey = BiasCellKey.make(
            line: "red",
            stopId: "30173",
            direction: "1",
            at: predictedArrivalAt,
            calendar: calendar
        )
        let cell = store.snapshot(key: expectedKey)
        #expect(cell != nil)
        #expect(cell?.count == 1)
        #expect(cell?.mean == 90)
    }

    @Test func resolutionUsesPredictedArrivalForBucketing() async throws {
        // The BiasCellKey timestamp must be `firstPredictedArrivalAt`
        // (when the train was *supposed* to be there) not
        // `observedCrossingAt` (the resolution moment). This matters when
        // resolution lands in a different hour-class than prediction.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bucket"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: calendar)

        // Predicted arrival at 9:55 (AM peak, hours 6–9) but resolution
        // lands at 10:05 (midday, hours 10–14) ten minutes late. Bucket
        // must reflect the *predicted* hour class, not the resolution one.
        let predictedArrivalAt = calendar.date(from: DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 5, day: 14, hour: 9, minute: 55
        ))!
        let arrival = makeArrival(
            predictedAt: predictedArrivalAt.addingTimeInterval(-5 * 60),
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([arrival], now: predictedArrivalAt.addingTimeInterval(-5 * 60))

        await grader.ingestPositions(
            [makePosition(nextStopId: 30173, observedAt: predictedArrivalAt.addingTimeInterval(-60))],
            now: predictedArrivalAt.addingTimeInterval(-60)
        )
        let observedAt = predictedArrivalAt.addingTimeInterval(10 * 60)
        await grader.ingestPositions(
            [makePosition(nextStopId: 30174, observedAt: observedAt)],
            now: observedAt
        )

        let peakBucket = BiasCellKey.make(
            line: "red",
            stopId: "30173",
            direction: "1",
            at: predictedArrivalAt,
            calendar: calendar
        )
        let middayBucket = BiasCellKey.make(
            line: "red",
            stopId: "30173",
            direction: "1",
            at: observedAt,
            calendar: calendar
        )
        // Sanity: the two buckets should actually differ. If this assertion
        // fails on a future bucket-rule change, regenerate the times above.
        #expect(peakBucket != middayBucket)
        #expect(store.snapshot(key: peakBucket) != nil)
        #expect(store.snapshot(key: middayBucket) == nil)
    }

    // MARK: - Expiry

    @Test func pendingExpiresAfter30MinPastPredictedArrival() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-expire"))
        let grader = ArrivalGrader(biasStore: store)

        let arrival = makeArrival(
            predictedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        await grader.ingestArrivals([arrival], now: t0)
        #expect(grader.pendingCountForTests == 1)

        // Walk the clock to 36 min past predicted arrival, with an empty
        // positions snapshot — the expiry pass should clean up.
        let later = arrival.arrivalAt.addingTimeInterval(31 * 60)
        await grader.ingestPositions([], now: later)
        #expect(grader.pendingCountForTests == 0)
    }

    @Test func runDroppedFromMapAfter60MinSilence() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-runttl"))
        let grader = ArrivalGrader(biasStore: store)

        // Seed the previousNextStopByRun map with one position snapshot.
        let firstSeen = t0
        await grader.ingestPositions(
            [makePosition(nextStopId: 30173, observedAt: firstSeen)],
            now: firstSeen
        )
        #expect(grader.trackedRunCountForTests == 1)

        // 30 min later — empty snapshot, run not seen but still inside
        // the 60-min TTL.
        await grader.ingestPositions([], now: firstSeen.addingTimeInterval(30 * 60))
        #expect(grader.trackedRunCountForTests == 1)

        // 61 min later — past the TTL, run should be evicted.
        await grader.ingestPositions([], now: firstSeen.addingTimeInterval(61 * 60))
        #expect(grader.trackedRunCountForTests == 0)
    }

    @Test func nonTrainPositionsAreIgnored() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bus"))
        let grader = ArrivalGrader(biasStore: store)

        // Bus position should not enter the previous-next-stop map (Phase
        // 2 is train-only).
        let bus = makePosition(
            runNumber: "1841",
            route: "22",
            nextStopId: 4000,
            observedAt: t0,
            mode: .bus
        )
        await grader.ingestPositions([bus], now: t0)
        #expect(grader.trackedRunCountForTests == 0)
    }

    // MARK: - ingestBoardingEvent (Phase 4)

    @Test func boardingResolvesSinglePendingGradeWithinWindow() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-single"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let arrival = makeArrival(
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([arrival], now: t0)
        #expect(grader.pendingCountForTests == 1)

        // Board 90 seconds after the predicted arrival → API was early by 90s.
        let boardingAt = predictedArrivalAt.addingTimeInterval(90)
        let resolved = await grader.ingestBoardingEvent(
            stationId: arrival.stationId,
            observedAt: boardingAt
        )

        #expect(resolved == 1)
        #expect(grader.pendingCountForTests == 0)
        let cellKey = BiasCellKey.make(
            line: arrival.line.rawValue,
            stopId: String(arrival.stopId),
            direction: arrival.directionCode,
            at: predictedArrivalAt
        )
        let cell = store.snapshot(key: cellKey)
        #expect(cell?.count == 1)
        #expect(cell?.mean == 90)
    }

    @Test func boardingWithNoPendingGradesReturnsZero() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-none"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let resolved = await grader.ingestBoardingEvent(
            stationId: 40900,
            observedAt: t0
        )
        #expect(resolved == 0)
    }

    @Test func boardingOutsideWindowDoesNotResolve() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-late"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let arrival = makeArrival(
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([arrival], now: t0)

        // Board 4 minutes after the predicted arrival → outside the default
        // ±3-min match window.
        let boardingAt = predictedArrivalAt.addingTimeInterval(4 * 60)
        let resolved = await grader.ingestBoardingEvent(
            stationId: arrival.stationId,
            observedAt: boardingAt
        )

        #expect(resolved == 0)
        // Pending grade should still be there.
        #expect(grader.pendingCountForTests == 1)
    }

    @Test func boardingResolvesAllPendingLinesAtSameStation() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-multi"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let red = makeArrival(
            line: .red,
            runNumber: "401",
            stopId: 30173,
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        let brown = makeArrival(
            line: .brown,
            runNumber: "501",
            stopId: 30174,
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([red, brown], now: t0)
        #expect(grader.pendingCountForTests == 2)

        let boardingAt = predictedArrivalAt.addingTimeInterval(60)
        let resolved = await grader.ingestBoardingEvent(
            stationId: red.stationId,  // both arrivals share stationId 40900
            observedAt: boardingAt
        )

        // Both pending grades at this station resolve.
        #expect(resolved == 2)
        #expect(grader.pendingCountForTests == 0)
    }

    @Test func boardingAtDifferentStationDoesNotResolve() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-other"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let arrival = makeArrival(
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([arrival], now: t0)

        // arrival.stationId is 40900 (the makeArrival default).
        let resolved = await grader.ingestBoardingEvent(
            stationId: 99999,  // an unrelated station
            observedAt: predictedArrivalAt.addingTimeInterval(60)
        )

        #expect(resolved == 0)
        #expect(grader.pendingCountForTests == 1)
    }

    @Test func boardingPreventsDoubleWriteFromLaterPositionTransition() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-double"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrivalAt = t0.addingTimeInterval(5 * 60)
        let arrival = makeArrival(
            predictedAt: t0,
            arrivalAt: predictedArrivalAt
        )
        await grader.ingestArrivals([arrival], now: t0)

        // User boards — resolves the pending grade as a Phase 4 sample.
        let boardingAt = predictedArrivalAt.addingTimeInterval(60)
        _ = await grader.ingestBoardingEvent(
            stationId: arrival.stationId,
            observedAt: boardingAt
        )
        #expect(grader.pendingCountForTests == 0)

        // Now a later position-snapshot transition arrives for the SAME run
        // at the SAME stop. The pending entry was already removed, so passive
        // grading must not write a second sample.
        let firstPosition = makePosition(
            nextStopId: arrival.stopId,
            observedAt: boardingAt.addingTimeInterval(30)
        )
        await grader.ingestPositions([firstPosition], now: boardingAt.addingTimeInterval(30))
        let secondPosition = makePosition(
            nextStopId: arrival.stopId + 1,
            observedAt: boardingAt.addingTimeInterval(120)
        )
        await grader.ingestPositions([secondPosition], now: boardingAt.addingTimeInterval(120))

        // Sample count should still be 1 — only the boarding event wrote.
        let cellKey = BiasCellKey.make(
            line: arrival.line.rawValue,
            stopId: String(arrival.stopId),
            direction: arrival.directionCode,
            at: predictedArrivalAt
        )
        #expect(store.snapshot(key: cellKey)?.count == 1)
    }

    @Test func boardingFallsBackToZeroWhenStationMapEmpty() async throws {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-board-empty"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        // No ingestArrivals call → stationIdByStopId is empty. Even if we
        // hypothetically forged a pending entry (we can't, the map is
        // private), a boarding event can't resolve anything.
        let resolved = await grader.ingestBoardingEvent(
            stationId: 40900,
            observedAt: t0
        )
        #expect(resolved == 0)
    }

    // MARK: - ingestBusPredictions

    private func makeBusPrediction(
        route: String = "22",
        vehicleId: String = "1841",
        stopId: Int = 1818,
        directionName: String = "Northbound",
        generatedAt: Date,
        arrivalAt: Date
    ) -> BusPrediction {
        BusPrediction(
            id: "\(route)-\(vehicleId)-\(stopId)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            route: route,
            routeName: "Clark",
            vehicleId: vehicleId,
            stopId: stopId,
            stopName: "Clark & Division",
            destinationName: "Howard",
            directionName: directionName,
            generatedAt: generatedAt,
            arrivalAt: arrivalAt,
            isDelayed: false,
            isApproaching: false
        )
    }

    @Test func busIngestSkipsPredictionsInsideLeadTimeWindow() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bus-leadtime"))
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let tooClose = makeBusPrediction(
            generatedAt: t0,
            arrivalAt: t0.addingTimeInterval(2 * 60)
        )
        let okPrediction = makeBusPrediction(
            vehicleId: "1842",
            stopId: 1820,
            generatedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        await grader.ingestBusPredictions([tooClose, okPrediction], now: t0)
        #expect(grader.pendingCountForTests == 1)
    }

    @Test func busIngestFirstPredictionWins() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bus-firstwin"))
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let firstArrival = t0.addingTimeInterval(5 * 60)
        let original = makeBusPrediction(generatedAt: t0, arrivalAt: firstArrival)
        let updated = makeBusPrediction(generatedAt: t0.addingTimeInterval(60), arrivalAt: firstArrival.addingTimeInterval(120))

        await grader.ingestBusPredictions([original], now: t0)
        await grader.ingestBusPredictions([updated], now: t0.addingTimeInterval(60))
        #expect(grader.pendingCountForTests == 1)
        // The pending grade's firstPredictedArrivalAt should still be the
        // original (5 min), not the updated (7 min). This is the
        // load-bearing "API doesn't grade itself by re-predicting" guard.
        let pending = grader._pendingForTests(line: "22", runNumber: "1841", stopId: 1818)
        #expect(pending != nil)
        #expect(pending?.firstPredictedArrivalAt == firstArrival)
    }

    // MARK: - bus position crossing resolution

    @Test func busPositionTransitionResolvesPendingGrade() async {
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bus-crossing"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let predictedArrival = t0.addingTimeInterval(5 * 60)
        let prediction = makeBusPrediction(generatedAt: t0, arrivalAt: predictedArrival)
        await grader.ingestBusPredictions([prediction], now: t0)
        #expect(grader.pendingCountForTests == 1)

        // First snapshot: bus heading to our stop (id 1818).
        let frame1 = makePosition(
            runNumber: "1841",
            route: "22",
            nextStopId: 1818,
            observedAt: t0.addingTimeInterval(3 * 60),
            mode: .bus
        )
        await grader.ingestPositions([frame1], now: t0.addingTimeInterval(3 * 60))

        // Second snapshot: bus has rolled past 1818, now heading to 1819.
        // Crossed-at timestamp = observedAt of frame2.
        let observedCrossingAt = t0.addingTimeInterval(6 * 60)
        let frame2 = makePosition(
            runNumber: "1841",
            route: "22",
            nextStopId: 1819,
            observedAt: observedCrossingAt,
            mode: .bus
        )
        await grader.ingestPositions([frame2], now: observedCrossingAt)

        // Sample written: bus arrived 1 min late (predicted 5 min,
        // observed 6 min). Welford delta = +60 s.
        let cellKey = BiasCellKey.make(
            line: "22",
            stopId: "1818",
            direction: "Northbound",
            at: predictedArrival
        )
        let cell = store.snapshot(key: cellKey)
        #expect(cell?.count == 1)
        #expect(abs((cell?.mean ?? 0) - 60) < 1e-9)
        #expect(grader.pendingCountForTests == 0)
    }

    @Test func busVehicleIdCollidingWithTrainRunDoesNotCrossContaminate() async {
        // A bus and a train both happen to use id "401". The split
        // previous-snapshot maps must keep them independent — a bus
        // crossing shouldn't fire against a stale train run entry and
        // vice versa.
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-bus-collision"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        // Train prediction at stopId 30173.
        let trainArrival = makeArrival(
            line: .red,
            runNumber: "401",
            stopId: 30173,
            predictedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        // Bus prediction with id "401" at stopId 1818.
        let busPrediction = makeBusPrediction(
            route: "22",
            vehicleId: "401",
            stopId: 1818,
            generatedAt: t0,
            arrivalAt: t0.addingTimeInterval(5 * 60)
        )
        await grader.ingestArrivals([trainArrival], now: t0)
        await grader.ingestBusPredictions([busPrediction], now: t0)
        #expect(grader.pendingCountForTests == 2)

        // Frame 1: train sees 30173, bus sees 1818. Both separate.
        let frame1Train = makePosition(
            runNumber: "401", route: "red",
            nextStopId: 30173, observedAt: t0.addingTimeInterval(3 * 60),
            mode: .train
        )
        let frame1Bus = makePosition(
            runNumber: "401", route: "22",
            nextStopId: 1818, observedAt: t0.addingTimeInterval(3 * 60),
            mode: .bus
        )
        await grader.ingestPositions([frame1Train, frame1Bus], now: t0.addingTimeInterval(3 * 60))

        // Frame 2: train rolls past 30173, bus rolls past 1818.
        let frame2Train = makePosition(
            runNumber: "401", route: "red",
            nextStopId: 30174, observedAt: t0.addingTimeInterval(6 * 60),
            mode: .train
        )
        let frame2Bus = makePosition(
            runNumber: "401", route: "22",
            nextStopId: 1819, observedAt: t0.addingTimeInterval(6 * 60),
            mode: .bus
        )
        await grader.ingestPositions([frame2Train, frame2Bus], now: t0.addingTimeInterval(6 * 60))

        // Both pending grades resolve cleanly — no cross-contamination.
        #expect(grader.pendingCountForTests == 0)

        // Train cell key uses "red" / "30173", bus cell key uses
        // "22" / "1818". Neither should contain the other's sample.
        let trainKey = BiasCellKey.make(
            line: "red", stopId: "30173", direction: "1",
            at: trainArrival.arrivalAt
        )
        let busKey = BiasCellKey.make(
            line: "22", stopId: "1818", direction: "Northbound",
            at: busPrediction.arrivalAt
        )
        #expect(store.snapshot(key: trainKey)?.count == 1)
        #expect(store.snapshot(key: busKey)?.count == 1)
    }

    @Test func metraPositionsAreIgnoredByGrader() async {
        // Metra `VehiclePosition.nextStopId` is a stop sequence index,
        // not a stop id, so it would falsely match if we processed it.
        // Verify positions of mode .metra are silently skipped.
        let store = ArrivalBiasStore(fileURL: Self.temporaryFile(name: "Grader-metra-skip"))
        await store.hydrateFromDiskIfNeeded()
        let grader = ArrivalGrader(biasStore: store, calendar: .current)

        let frame1 = makePosition(
            runNumber: "UPN-12345", route: "UP-N",
            nextStopId: 5, observedAt: t0,
            mode: .metra
        )
        let frame2 = makePosition(
            runNumber: "UPN-12345", route: "UP-N",
            nextStopId: 6, observedAt: t0.addingTimeInterval(60),
            mode: .metra
        )
        await grader.ingestPositions([frame1], now: t0)
        await grader.ingestPositions([frame2], now: t0.addingTimeInterval(60))

        // Metra positions don't seed `previousNextStopByBusVehicle` or
        // `previousNextStopByTrainRun` — they're tracked nowhere.
        #expect(grader.trackedRunCountForTests == 0)
        #expect(grader.trackedBusVehicleCountForTests == 0)
    }

    // MARK: - Helpers

    static func temporaryFile(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrivalGraderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }
}
