import Foundation
import Testing
@testable import TransitModels

@Suite("ArrivalBiasCorrection gating and display")
struct ArrivalBiasCorrectionTests {
    /// Build a cell that lands exactly on the requested `mean` and `stddev`
    /// for a given `count` by handing it a synthetic Welford state. We go
    /// through `BiasCell.init` directly because `recordSample` only takes
    /// data; this is the cleanest way to test the gate logic without
    /// hand-crafting many samples.
    ///
    /// `m2 = stddev^2 * (count - 1)` reverses the Welford variance formula.
    private func cell(count: Int, mean: Double, stddev: Double) -> BiasCell {
        let variance = stddev * stddev
        let m2 = variance * Double(max(count - 1, 0))
        return BiasCell(count: count, mean: mean, m2: m2, lastUpdatedAt: .distantPast)
    }

    // MARK: - Gates

    @Test func returnsNilWhenCellIsNil() {
        #expect(ArrivalBiasCorrection.from(cell: nil) == nil)
    }

    @Test func returnsNilBelowSampleCount() {
        // High mean, low variance — but only 11 samples (gate is 12).
        let c = cell(count: 11, mean: 120, stddev: 10)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
    }

    @Test func returnsNilBelowMagnitudeThreshold() {
        // 89s mean — just below the 90s floor.
        let c = cell(count: 50, mean: 89, stddev: 10)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
    }

    @Test func returnsNilWhenConfidenceFails() {
        // mean = 100s, stddev = 400s, count = 16 → stderr = 100, gate is 150.
        // |mean| = 100, not > 150 → fails.
        let c = cell(count: 16, mean: 100, stddev: 400)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
    }

    @Test func returnsNilWhenStdDevUnavailable() {
        // Single sample → variance = nil → gate cannot evaluate, return nil.
        // (`abs(mean) >= 90` is satisfied to make sure THIS gate is the one
        // that fails.)
        let c = cell(count: 1, mean: 200, stddev: 0)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
    }

    @Test func returnsNilWhenStdDevIsZero() {
        // Two identical samples → stddev = 0. We bail before SE math
        // because zero variance can't represent any meaningful spread.
        let c = cell(count: 12, mean: 120, stddev: 0)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
    }

    @Test func passesGatesWithPositiveMean() {
        // mean = +180s, stddev = 60s, count = 36 → stderr = 10 → gate = 15.
        // |mean| 180 > 15 ✓; count 36 >= 12 ✓; |mean| 180 >= 90 ✓.
        let c = cell(count: 36, mean: 180, stddev: 60)
        let correction = ArrivalBiasCorrection.from(cell: c)
        #expect(correction != nil)
        #expect(correction?.direction == .apiEarly)
        #expect(correction?.magnitudeSeconds == 180)
    }

    @Test func passesGatesWithNegativeMean() {
        // Symmetric: -180s mean → apiLate, magnitude is positive.
        let c = cell(count: 36, mean: -180, stddev: 60)
        let correction = ArrivalBiasCorrection.from(cell: c)
        #expect(correction != nil)
        #expect(correction?.direction == .apiLate)
        #expect(correction?.magnitudeSeconds == 180)
    }

    @Test func customThresholdsCanLetWeakerSignalsThrough() {
        // Same cell that failed the default count gate, but a custom
        // minSampleCount of 5 lets it pass. Sanity check that the
        // thresholds are actually configurable.
        let c = cell(count: 8, mean: 200, stddev: 60)
        #expect(ArrivalBiasCorrection.from(cell: c) == nil)
        let relaxed = ArrivalBiasCorrection.from(cell: c, minSampleCount: 5)
        #expect(relaxed != nil)
    }

    // MARK: - Display

    @Test func displayTextPositive() {
        let correction = ArrivalBiasCorrection(direction: .apiEarly, magnitudeSeconds: 120)
        #expect(correction.displayText == "usually +2m")
    }

    @Test func displayTextNegativeUsesRealMinus() {
        let correction = ArrivalBiasCorrection(direction: .apiLate, magnitudeSeconds: 60)
        // U+2212 minus sign, not an ASCII hyphen.
        #expect(correction.displayText == "usually \u{2212}1m")
    }

    @Test func displayTextLargeMagnitude() {
        let correction = ArrivalBiasCorrection(direction: .apiEarly, magnitudeSeconds: 900)
        #expect(correction.displayText == "usually +15m")
    }

    @Test func displayTextRoundsToZeroForTinyMagnitude() {
        // This can't actually happen post-gates (90s floor → minutes >= 2).
        // But if a caller constructs the value directly we render `+0m`
        // rather than swallow it — that's a useful diagnostic surface.
        let correction = ArrivalBiasCorrection(direction: .apiEarly, magnitudeSeconds: 15)
        #expect(correction.displayText == "usually +0m")
    }

    @Test func accessibilityLabelSpellsOutDirection() {
        let early = ArrivalBiasCorrection(direction: .apiEarly, magnitudeSeconds: 120)
        #expect(early.accessibilityLabel == "Usually 2 minutes later than predicted")
        let late = ArrivalBiasCorrection(direction: .apiLate, magnitudeSeconds: 60)
        #expect(late.accessibilityLabel == "Usually 1 minute earlier than predicted")
    }
}
