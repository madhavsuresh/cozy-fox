import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("DivvyClassicKernel")
struct DivvyClassicKernelTests {
    @Test func summaryMeanReflectsRideAndDockPenalty() async {
        let provider = DivvyPredictionStub(
            usableClassicProbability: 0.8,
            dockProbability: 0.7,
            classicRideMean: 600,
            classicRideSigma: 30
        )
        let kernel = DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider,
            dockFullRecoverySeconds: 300
        )
        let prepared = await kernel.prepare()
        let summary = prepared.summary()
        let expectedMean = 600 + (1 - 0.7) * 300
        #expect(abs(summary.mean - expectedMean) < 1)
    }

    @Test func pickupFailureMarksLegAsFailed() async {
        let provider = DivvyPredictionStub(usableClassicProbability: 0.0)
        let kernel = DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(outcome.didFail)
        #expect(outcome.failureReason?.contains("classic") == true)
    }

    @Test func dockSuccessReturnsCleanRide() async {
        let provider = DivvyPredictionStub(
            usableClassicProbability: 1.0,
            dockProbability: 1.0,
            classicRideMean: 600,
            classicRideSigma: 0
        )
        let kernel = DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(!outcome.didFail)
        #expect(outcome.totalDuration == 600)
    }

    @Test func dockFullAddsRecoveryButDoesNotFail() async {
        let provider = DivvyPredictionStub(
            usableClassicProbability: 1.0,
            dockProbability: 0.0,
            classicRideMean: 600,
            classicRideSigma: 0
        )
        let kernel = DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider,
            dockFullRecoverySeconds: 300,
            dockFullRecoverySigmaSeconds: 0
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(!outcome.didFail)
        #expect(outcome.totalDuration == 900)
    }

    @Test func deterministicAcrossSampleRunsForFixedSeed() async {
        let provider = DivvyPredictionStub()
        let kernel = DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider
        )
        let prepared = await kernel.prepare()
        var rngA = SeededLCG(seed: 42)
        var rngB = SeededLCG(seed: 42)
        var sumA: TimeInterval = 0
        var sumB: TimeInterval = 0
        for _ in 0..<128 {
            sumA += prepared.sample(startingAt: .distantPast, rng: &rngA).totalDuration
            sumB += prepared.sample(startingAt: .distantPast, rng: &rngB).totalDuration
        }
        #expect(sumA == sumB)
    }
}
