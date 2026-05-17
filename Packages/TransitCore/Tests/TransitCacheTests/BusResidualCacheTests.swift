import Foundation
import SwiftData
import Testing
@testable import TransitCache
import TransitModels

@Suite("Bus residual cache")
struct BusResidualCacheTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func residual(
        residualSeconds: Double,
        route: String = "65",
        stopId: Int = 456,
        directionName: String = "Westbound",
        horizonBucket: BusHorizonBucket = .under5min,
        hourOfWeek: Int = 49
    ) -> BusPredictionResidual {
        BusPredictionResidual(
            route: route,
            directionName: directionName,
            stopId: stopId,
            vehicleId: "1234",
            predictedAt: t0,
            predictedArrivalAt: t0.addingTimeInterval(180),
            confirmedArrivalAt: t0.addingTimeInterval(180 + residualSeconds),
            horizonBucket: horizonBucket,
            hourOfWeek: hourOfWeek,
            residualSeconds: residualSeconds
        )
    }

    @Test func recordingResidualCreatesBinAndUpdatesIt() async throws {
        let container = try ModelContainer.ephemeral()
        let store = TransitStore(container: container)

        await store.recordBusResidual(residual(residualSeconds: 30))
        var bin = await store.residualBin(
            route: "65", directionName: "Westbound", stopId: 456,
            horizonBucket: .under5min, hourOfWeek: 49
        )
        #expect(bin?.sampleCount == 1)
        #expect(bin?.q50Seconds == 30)

        await store.recordBusResidual(residual(residualSeconds: 90))
        await store.recordBusResidual(residual(residualSeconds: 60))
        await store.recordBusResidual(residual(residualSeconds: 120))
        await store.recordBusResidual(residual(residualSeconds: 0))

        bin = await store.residualBin(
            route: "65", directionName: "Westbound", stopId: 456,
            horizonBucket: .under5min, hourOfWeek: 49
        )
        #expect(bin?.sampleCount == 5)
        // Sorted: [0, 30, 60, 90, 120]. q50 → 60.
        #expect(bin?.q50Seconds == 60)
        // q10 / q90 with linear interp on 5 samples:
        //   position 0.4 → between sorted[0]=0 and sorted[1]=30 → 12
        //   position 3.6 → between sorted[3]=90 and sorted[4]=120 → 108
        #expect(abs((bin?.q10Seconds ?? -1) - 12) < 1e-9)
        #expect(abs((bin?.q90Seconds ?? -1) - 108) < 1e-9)
    }

    @Test func differentBinsDoNotCommingle() async throws {
        let container = try ModelContainer.ephemeral()
        let store = TransitStore(container: container)

        // Two different hour-of-week buckets for the same stop.
        await store.recordBusResidual(residual(residualSeconds: 100, hourOfWeek: 49))
        await store.recordBusResidual(residual(residualSeconds: -30, hourOfWeek: 50))

        let morning = await store.residualBin(
            route: "65", directionName: "Westbound", stopId: 456,
            horizonBucket: .under5min, hourOfWeek: 49
        )
        let evening = await store.residualBin(
            route: "65", directionName: "Westbound", stopId: 456,
            horizonBucket: .under5min, hourOfWeek: 50
        )

        #expect(morning?.sampleCount == 1)
        #expect(morning?.q50Seconds == 100)
        #expect(evening?.sampleCount == 1)
        #expect(evening?.q50Seconds == -30)
    }

    @Test func emptyLookupReturnsNil() async throws {
        let container = try ModelContainer.ephemeral()
        let store = TransitStore(container: container)

        let bin = await store.residualBin(
            route: "65", directionName: "Westbound", stopId: 999,
            horizonBucket: .under5min, hourOfWeek: 0
        )
        #expect(bin == nil)
    }

    @Test func allBusResidualsExposesRawRows() async throws {
        let container = try ModelContainer.ephemeral()
        let store = TransitStore(container: container)

        await store.recordBusResidual(residual(residualSeconds: 10))
        await store.recordBusResidual(residual(residualSeconds: 20))

        let rows = await store.allBusResiduals()
        #expect(rows.count == 2)
        #expect(rows.map(\.residualSeconds).sorted() == [10, 20])
    }
}

@Suite("BusHorizonBucket boundaries")
struct BusHorizonBucketTests {
    @Test func bucketsMapHorizonToCorrectRange() {
        #expect(BusHorizonBucket.bucket(for: 0) == .under2min)
        #expect(BusHorizonBucket.bucket(for: 119) == .under2min)
        #expect(BusHorizonBucket.bucket(for: 120) == .under5min)
        #expect(BusHorizonBucket.bucket(for: 299) == .under5min)
        #expect(BusHorizonBucket.bucket(for: 300) == .under10min)
        #expect(BusHorizonBucket.bucket(for: 599) == .under10min)
        #expect(BusHorizonBucket.bucket(for: 600) == .under20min)
        #expect(BusHorizonBucket.bucket(for: 1199) == .under20min)
        #expect(BusHorizonBucket.bucket(for: 1200) == .under1hour)
        #expect(BusHorizonBucket.bucket(for: 3599) == .under1hour)
        #expect(BusHorizonBucket.bucket(for: 3600) == .over1hour)
        #expect(BusHorizonBucket.bucket(for: 10_000) == .over1hour)
    }

    @Test func negativeHorizonClampsToShortest() {
        #expect(BusHorizonBucket.bucket(for: -60) == .under2min)
    }
}

@Suite("BusHourOfWeek")
struct BusHourOfWeekTests {
    @Test func sundayMidnightIsZero() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        // Sunday 2026-05-17 00:00 Chicago time. weekday=1, hour=0.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 17
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Chicago")
        let date = calendar.date(from: comps)!
        #expect(BusHourOfWeek.value(for: date, calendar: calendar) == 0)
    }

    @Test func wednesdayEveningRushIsExpected() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        // Wed 2026-05-20 18:00 Chicago — the user's #65 evening case.
        // weekday=4, hour=18 → (4-1)*24 + 18 = 90.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 20
        comps.hour = 18; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "America/Chicago")
        let date = calendar.date(from: comps)!
        #expect(BusHourOfWeek.value(for: date, calendar: calendar) == 90)
    }
}
