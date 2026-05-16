import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("TransitLegKernel")
struct TransitLegKernelTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func process(_ minutesAhead: [Double], feed: FeedState = .fresh, headway: TimeInterval? = nil) -> StopArrivalProcess {
        StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: minutesAhead.map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval($0 * 60)) },
            scheduleHeadwaySeconds: headway,
            feedState: feed
        )
    }

    @Test func sampleMeanApproachesWaitPlusInVehicleAcrossManyDraws() async {
        let kernel = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([5, 13, 21, 29]),
            inVehicleMean: 1200,
            inVehicleSigma: 60
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        var sum: TimeInterval = 0
        let n = 2048
        for _ in 0..<n {
            sum += prepared.sample(startingAt: Self.t0, rng: &rng).totalDuration
        }
        let mean = sum / Double(n)
        let expected: TimeInterval = 5 * 60 + 1200
        #expect(abs(mean - expected) < 30)
    }

    @Test func summaryReportsCombinedQuantiles() async {
        let kernel = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([5, 13, 21, 29]),
            inVehicleMean: 600,
            inVehicleSigma: 60
        )
        let prepared = await kernel.prepare()
        let summary = prepared.summary()
        #expect(summary.mean >= 600)
        #expect(summary.p80 >= summary.p50)
    }

    @Test func sampleFailsWhenWaitExceedsCutoff() async {
        let kernel = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([45]),
            inVehicleMean: 600,
            inVehicleSigma: 30,
            missCutoffSeconds: 10 * 60
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 7)
        let outcome = prepared.sample(startingAt: Self.t0, rng: &rng)
        #expect(outcome.didFail)
        #expect(outcome.failureReason?.contains("missed") == true)
    }

    @Test func deterministicForFixedSeed() async {
        let kernel = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([5, 13, 21, 29]),
            inVehicleMean: 600,
            inVehicleSigma: 60
        )
        let preparedA = await kernel.prepare()
        let preparedB = await kernel.prepare()
        var rngA = SeededLCG(seed: 42)
        var rngB = SeededLCG(seed: 42)
        let outcomeA = preparedA.sample(startingAt: Self.t0, rng: &rngA)
        let outcomeB = preparedB.sample(startingAt: Self.t0, rng: &rngB)
        #expect(outcomeA == outcomeB)
    }

    @Test func badGapStateInflatesWaitSigma() async {
        let normal = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([5, 13, 21, 29]),
            inVehicleMean: 600,
            inVehicleSigma: 0
        )
        let bad = TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: process([20, 32, 42, 52]),
            inVehicleMean: 600,
            inVehicleSigma: 0
        )
        let preparedN = await normal.prepare()
        let preparedB = await bad.prepare()
        #expect(preparedN.summary().p80 < preparedB.summary().p80)
    }
}
