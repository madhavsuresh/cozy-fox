import Foundation
import Testing
@testable import TransitDomain

@Suite("WalkSpeedTypes")
struct WalkSpeedTypesTests {

    // MARK: - WalkSpeedSample.ratio

    @Test func ratioIsActualOverExpected() {
        let sample = WalkSpeedSample(
            actualSeconds: 120,
            expectedSeconds: 100,
            recordedAt: Date()
        )
        #expect(sample.ratio == 1.2)
    }

    @Test func ratioWithZeroExpectedFallsBackToOne() {
        let sample = WalkSpeedSample(
            actualSeconds: 60,
            expectedSeconds: 0,
            recordedAt: Date()
        )
        #expect(sample.ratio == 1.0)
    }

    // MARK: - WalkSpeedEstimate.recordSample

    @Test func meanConvergesOnMultipleSamples() {
        var estimate = WalkSpeedEstimate.empty
        let when = Date()
        // Ratios 1.0, 1.2, 0.8 → mean = 1.0 exactly.
        estimate.recordSample(ratio: 1.0, at: when)
        estimate.recordSample(ratio: 1.2, at: when)
        estimate.recordSample(ratio: 0.8, at: when)
        #expect(estimate.count == 3)
        #expect(abs(estimate.mean - 1.0) < 1e-12)
    }

    @Test func meanFromSingleSampleEqualsSample() {
        var estimate = WalkSpeedEstimate.empty
        estimate.recordSample(ratio: 1.15, at: Date())
        #expect(estimate.count == 1)
        #expect(abs(estimate.mean - 1.15) < 1e-12)
    }

    @Test func meanIsOrderInvariant() {
        var a = WalkSpeedEstimate.empty
        var b = WalkSpeedEstimate.empty
        let samples = [0.9, 1.05, 1.1, 0.95, 1.2]
        let when = Date()
        for r in samples {
            a.recordSample(ratio: r, at: when)
        }
        for r in samples.reversed() {
            b.recordSample(ratio: r, at: when)
        }
        #expect(a.count == b.count)
        #expect(abs(a.mean - b.mean) < 1e-12)
        #expect(abs(a.m2 - b.m2) < 1e-9)
    }

    // MARK: - WalkSpeedEstimate.confidentRatio

    @Test func confidentRatioReturnsNilBelowGate() {
        var estimate = WalkSpeedEstimate.empty
        for _ in 0..<4 {
            estimate.recordSample(ratio: 1.2, at: Date())
        }
        #expect(estimate.count == 4)
        #expect(estimate.confidentRatio() == nil)
    }

    @Test func confidentRatioReturnsMeanAtGate() {
        var estimate = WalkSpeedEstimate.empty
        for _ in 0..<5 {
            estimate.recordSample(ratio: 1.2, at: Date())
        }
        #expect(estimate.count == 5)
        #expect(estimate.confidentRatio() != nil)
        #expect(abs((estimate.confidentRatio() ?? 0) - 1.2) < 1e-12)
    }

    @Test func confidentRatioHonorsCustomMinSamples() {
        var estimate = WalkSpeedEstimate.empty
        estimate.recordSample(ratio: 1.1, at: Date())
        estimate.recordSample(ratio: 1.1, at: Date())
        #expect(estimate.confidentRatio(minSamples: 5) == nil)
        #expect(estimate.confidentRatio(minSamples: 2) != nil)
    }

    // MARK: - empty default

    @Test func emptyDefaultsToNoOpMean() {
        let estimate = WalkSpeedEstimate.empty
        #expect(estimate.count == 0)
        #expect(estimate.mean == 1.0)
        #expect(estimate.m2 == 0)
        #expect(estimate.confidentRatio() == nil)
    }

    // MARK: - Codable round-trip

    @Test func codableRoundTripPreservesAllFields() throws {
        var estimate = WalkSpeedEstimate.empty
        estimate.recordSample(ratio: 1.15, at: Date())
        estimate.recordSample(ratio: 0.95, at: Date())
        estimate.recordSample(ratio: 1.05, at: Date())

        let encoded = try JSONEncoder().encode(estimate)
        let decoded = try JSONDecoder().decode(WalkSpeedEstimate.self, from: encoded)

        #expect(decoded.count == estimate.count)
        #expect(abs(decoded.mean - estimate.mean) < 1e-12)
        #expect(abs(decoded.m2 - estimate.m2) < 1e-12)
    }
}
