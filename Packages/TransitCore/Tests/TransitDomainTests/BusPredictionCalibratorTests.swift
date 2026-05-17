import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BusPredictionCalibrator")
struct BusPredictionCalibratorTests {
    // Wed 2026-05-20 17:56 Chicago. arrivalAt = +4 min = 18:00 →
    // weekday=4, hour=18 → hourOfWeek 90. (BusHourOfWeek bins on the
    // *arrival* time, not the snapshot time.)
    private static let predictedAt: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 20
        comps.hour = 17; comps.minute = 56
        comps.timeZone = TimeZone(identifier: "America/Chicago")
        return calendar.date(from: comps)!
    }()

    private static let arrivalAt = predictedAt.addingTimeInterval(4 * 60)
    private static let calendar = Calendar.currentChicago

    private func prediction(
        id: String = "65-456-test",
        route: String = "65",
        directionName: String = "Westbound",
        stopId: Int = 456
    ) -> BusPrediction {
        BusPrediction(
            id: id,
            route: route,
            routeName: "65 Grand",
            vehicleId: "1234",
            stopId: stopId,
            stopName: "Grand & McClurg",
            destinationName: "Grand/Nordica",
            directionName: directionName,
            generatedAt: Self.predictedAt,
            arrivalAt: Self.arrivalAt,
            isDelayed: false,
            isApproaching: false
        )
    }

    private func bin(
        q50: Double,
        sampleCount: Int = 20,
        route: String = "65",
        directionName: String = "Westbound",
        stopId: Int = 456,
        horizon: BusHorizonBucket = .under5min,
        hourOfWeek: Int = 90
    ) -> BusResidualQuantileBin {
        BusResidualQuantileBin(
            route: route,
            directionName: directionName,
            stopId: stopId,
            horizonBucket: horizon,
            hourOfWeek: hourOfWeek,
            sampleCount: sampleCount,
            q10Seconds: q50 - 30,
            q50Seconds: q50,
            q90Seconds: q50 + 30,
            lastUpdated: Date()
        )
    }

    @Test("Exact stratum match shifts arrivalAt by q50")
    func exactStratumShifts() {
        let pred = prediction()
        let bins = [bin(q50: 60)]  // bus tends to be 60s later than CTA says

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: bins,
            calendar: Self.calendar
        )

        #expect(result.stratum == .exact)
        #expect(result.appliedShiftSeconds == 60)
        #expect(result.prediction.arrivalAt == pred.arrivalAt.addingTimeInterval(60))
    }

    @Test("No matching bin → prediction passes through untouched")
    func noBinPassesThrough() {
        let pred = prediction()
        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [],
            calendar: Self.calendar
        )

        #expect(result.stratum == nil)
        #expect(result.appliedShiftSeconds == 0)
        #expect(result.prediction.arrivalAt == pred.arrivalAt)
    }

    @Test("Bin under minSamples → falls back to a coarser stratum")
    func belowMinSamplesFallsBack() {
        let pred = prediction()
        let exactSparse = bin(q50: 999, sampleCount: 2, hourOfWeek: 90)
        let coarser = bin(q50: 45, sampleCount: 20, hourOfWeek: 91)
        // The coarser is also "exact" route+direction+stopId+horizon but a
        // different hourOfWeek — that's the dropped-hourOfWeek stratum.

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [exactSparse, coarser],
            calendar: Self.calendar
        )

        #expect(result.stratum == .droppedHourOfWeek)
        #expect(result.appliedShiftSeconds == 45)
    }

    @Test("Dropped hourOfWeek picks the highest-N bin in same stratum")
    func droppedHourOfWeekPicksMostSamples() {
        let pred = prediction()
        let cold = bin(q50: 999, sampleCount: 6, hourOfWeek: 89)
        let warm = bin(q50: 30, sampleCount: 40, hourOfWeek: 91)

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [cold, warm],
            calendar: Self.calendar
        )

        #expect(result.stratum == .droppedHourOfWeek)
        #expect(result.appliedShiftSeconds == 30)
    }

    @Test("Drops direction when route+stop+horizon match but direction doesn't")
    func droppedDirectionFallback() {
        let pred = prediction()
        let opposite = bin(q50: 120, directionName: "Eastbound", hourOfWeek: 89)

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [opposite],
            calendar: Self.calendar
        )

        #expect(result.stratum == .droppedDirection)
        #expect(result.appliedShiftSeconds == 120)
    }

    @Test("Drops stopId for a route-wide fallback when nothing closer matches")
    func droppedStopIdFallback() {
        let pred = prediction()
        let elsewhere = bin(q50: 90, directionName: "Eastbound", stopId: 999)

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [elsewhere],
            calendar: Self.calendar
        )

        #expect(result.stratum == .droppedStopId)
        #expect(result.appliedShiftSeconds == 90)
    }

    @Test("Different horizon bucket never matches even at coarsest stratum")
    func wrongHorizonDoesNotMatch() {
        let pred = prediction()  // horizon ~4 min → under5min
        let wrongHorizon = bin(q50: 200, horizon: .under20min, hourOfWeek: 90)

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: [wrongHorizon],
            calendar: Self.calendar
        )

        #expect(result.stratum == nil)
        #expect(result.appliedShiftSeconds == 0)
    }

    @Test("Negative q50 (bus tends to be early) shifts arrival earlier")
    func negativeQ50ShiftsEarlier() {
        let pred = prediction()
        let bins = [bin(q50: -45)]

        let result = BusPredictionCalibrator.calibrate(
            pred,
            using: bins,
            calendar: Self.calendar
        )

        #expect(result.stratum == .exact)
        #expect(result.appliedShiftSeconds == -45)
        #expect(result.prediction.arrivalAt == pred.arrivalAt.addingTimeInterval(-45))
    }

    @Test("calibrateAll preserves input order")
    func calibrateAllPreservesOrder() {
        let pA = prediction(id: "A", route: "65")
        let pB = prediction(id: "B", route: "22")
        // Bin only matches route 65. Route 22 prediction has no bin at any
        // stratum (the route-wide fallback is keyed on the same route).
        let bins = [bin(q50: 60, route: "65")]

        let result = BusPredictionCalibrator.calibrateAll(
            [pA, pB],
            using: bins,
            calendar: Self.calendar
        )

        #expect(result.map(\.id) == ["A", "B"])
        // A was calibrated.
        #expect(result[0].arrivalAt == pA.arrivalAt.addingTimeInterval(60))
        // B is on a different route → no bin matches → unchanged.
        #expect(result[1].arrivalAt == pB.arrivalAt)
    }
}
