import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("WalkingKernel")
struct WalkingKernelTests {
    @Test func emptyEstimateUsesRatioOne() async {
        let kernel = WalkingKernel(
            expectedSeconds: 600,
            walkSpeedEstimate: .empty,
            jitterCoefficient: 0
        )
        let prepared = await kernel.prepare()
        #expect(prepared.meanSeconds == 600)
        #expect(prepared.appliedRatio == 1.0)
    }

    @Test func confidentRatioAppliedAfterEnoughSamples() async {
        var estimate = WalkSpeedEstimate.empty
        for _ in 0..<10 {
            estimate.recordSample(ratio: 1.2, at: .distantPast)
        }
        let kernel = WalkingKernel(
            expectedSeconds: 600,
            walkSpeedEstimate: estimate,
            jitterCoefficient: 0
        )
        let prepared = await kernel.prepare()
        #expect(prepared.appliedRatio == 1.2)
        #expect(abs(prepared.meanSeconds - 720) < 0.001)
    }

    @Test func sampleMeanApproachesExpectedAcrossManyDrawsWithSeed() async {
        let kernel = WalkingKernel(
            expectedSeconds: 600,
            walkSpeedEstimate: .empty,
            jitterCoefficient: 0.10
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 42)
        var sum: Double = 0
        let n = 1024
        for _ in 0..<n {
            sum += prepared.sample(startingAt: .distantPast, rng: &rng).totalDuration
        }
        let mean = sum / Double(n)
        #expect(abs(mean - 600) < 20)
    }

    @Test func zeroJitterProducesDeterministicOutput() async {
        let kernel = WalkingKernel(
            expectedSeconds: 480,
            walkSpeedEstimate: .empty,
            jitterCoefficient: 0
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(outcome.totalDuration == 480)
    }

    @Test func sampleClampedNonNegative() async {
        var estimate = WalkSpeedEstimate.empty
        for _ in 0..<10 {
            estimate.recordSample(ratio: 1.0, at: .distantPast)
        }
        let kernel = WalkingKernel(
            expectedSeconds: 30,
            walkSpeedEstimate: estimate,
            jitterCoefficient: 5.0
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 7)
        for _ in 0..<200 {
            let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
            #expect(outcome.totalDuration >= 0)
        }
    }

    @Test func summaryReflectsAppliedRatio() async {
        var estimate = WalkSpeedEstimate.empty
        for _ in 0..<10 {
            estimate.recordSample(ratio: 0.9, at: .distantPast)
        }
        let kernel = WalkingKernel(
            expectedSeconds: 600,
            walkSpeedEstimate: estimate,
            jitterCoefficient: 0.10
        )
        let prepared = await kernel.prepare()
        let summary = prepared.summary()
        #expect(abs(summary.p50 - 540) < 0.001)
        #expect(summary.p80 > summary.p50)
    }
}
