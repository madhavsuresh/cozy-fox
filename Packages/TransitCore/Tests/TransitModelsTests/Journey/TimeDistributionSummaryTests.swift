import Foundation
import Testing
@testable import TransitModels

@Suite("TimeDistributionSummary")
struct TimeDistributionSummaryTests {
    @Test func empiricalQuantilesOverTenSamples() {
        let samples = (1...10).map { TimeInterval($0 * 60) }
        let summary = TimeDistributionSummary.empirical(from: samples)
        #expect(summary.sampleCount == 10)
        #expect(summary.mean == 330)
        #expect(summary.p50 == 300)
        #expect(summary.p80 == 480)
        #expect(summary.p90 == 540)
    }

    @Test func empiricalEmptyReturnsZero() {
        let summary = TimeDistributionSummary.empirical(from: [])
        #expect(summary == .zero)
    }

    @Test func empiricalSingleSample() {
        let summary = TimeDistributionSummary.empirical(from: [120])
        #expect(summary.sampleCount == 1)
        #expect(summary.p50 == 120)
        #expect(summary.p80 == 120)
        #expect(summary.p90 == 120)
        #expect(summary.confidence < 0.05)
    }

    @Test func empiricalDropsNegativeAndNonFinite() {
        let summary = TimeDistributionSummary.empirical(from: [60, -10, .infinity, 120])
        #expect(summary.sampleCount == 2)
        #expect(summary.p50 == 60)
    }

    @Test func analyticConstructorMatchesGaussianQuantiles() {
        let summary = TimeDistributionSummary.analytic(
            mean: 600,
            standardDeviation: 120,
            confidence: 0.7,
            sampleCount: 5
        )
        #expect(summary.p50 == 600)
        #expect(abs(summary.p80 - (600 + 0.8416 * 120)) < 0.01)
        #expect(abs(summary.p90 - (600 + 1.2816 * 120)) < 0.01)
    }

    @Test func codableRoundTrip() throws {
        let original = TimeDistributionSummary(
            mean: 600, p50: 540, p80: 720, p90: 900,
            confidence: 0.6, sampleCount: 8
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimeDistributionSummary.self, from: data)
        #expect(decoded == original)
    }

    @Test func asSecondsRangeReturnsOrderedRange() {
        let summary = TimeDistributionSummary(
            mean: 600, p50: 540, p80: 720, p90: 900,
            confidence: 0.6, sampleCount: 8
        )
        let range = summary.asSecondsRange(low: .p50, high: .p90)
        #expect(range.lowerBound == 540)
        #expect(range.upperBound == 900)
    }

    @Test func asSecondsRangeFlipsBackwardArgs() {
        let summary = TimeDistributionSummary(
            mean: 600, p50: 540, p80: 720, p90: 900,
            confidence: 0.6, sampleCount: 8
        )
        let range = summary.asSecondsRange(low: .p90, high: .p50)
        #expect(range.lowerBound == 540)
        #expect(range.upperBound == 900)
    }

    @Test func confidenceClampedToUnitInterval() {
        let high = TimeDistributionSummary(mean: 0, p50: 0, p80: 0, p90: 0, confidence: 2.5, sampleCount: 1)
        let low = TimeDistributionSummary(mean: 0, p50: 0, p80: 0, p90: 0, confidence: -0.5, sampleCount: 1)
        #expect(high.confidence == 1)
        #expect(low.confidence == 0)
    }
}
