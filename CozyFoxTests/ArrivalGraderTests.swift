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

    // MARK: - Helpers

    static func temporaryFile(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrivalGraderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }
}
