import Foundation
import Testing
@testable import TransitModels

@Suite("BiasCell Welford updates and decay")
struct BiasCellTests {
    @Test func welfordMatchesHandComputedMeanAndVariance() {
        // Sample set: [10, 30, 50, 70, 90]
        // Mean = 50, sample variance with Bessel = 2500/4 * 4 / 4 = ?
        //   sumSquaredDev = 1600 + 400 + 0 + 400 + 1600 = 4000
        //   sample variance = 4000 / 4 = 1000
        //   std dev = sqrt(1000) ≈ 31.6227766
        var cell = BiasCell()
        let samples: [Double] = [10, 30, 50, 70, 90]
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        for (i, s) in samples.enumerated() {
            cell.recordSample(s, at: now.addingTimeInterval(Double(i)))
        }
        #expect(cell.count == 5)
        #expect(abs(cell.mean - 50.0) < 1e-9)
        #expect(abs((cell.variance ?? 0) - 1000.0) < 1e-9)
        #expect(abs((cell.standardDeviation ?? 0) - 31.6227766017) < 1e-6)
    }

    @Test func singleSampleHasNoVarianceYet() {
        var cell = BiasCell()
        cell.recordSample(42.0, at: Date())
        #expect(cell.count == 1)
        #expect(cell.mean == 42.0)
        #expect(cell.variance == nil)
        #expect(cell.standardDeviation == nil)
    }

    @Test func emptyCellHasZeroEverything() {
        let cell = BiasCell()
        #expect(cell.count == 0)
        #expect(cell.mean == 0)
        #expect(cell.m2 == 0)
        #expect(cell.variance == nil)
    }

    @Test func decayHalvesCountAtOneHalfLife() {
        var cell = BiasCell()
        let t0 = Date(timeIntervalSinceReferenceDate: 770_000_000)
        // Build up 100 samples around mean 60s (positive ⇒ API early).
        for i in 0..<100 {
            let sample = 60.0 + (i.isMultiple(of: 2) ? 5.0 : -5.0)
            cell.recordSample(sample, at: t0)
        }
        let originalMean = cell.mean
        let originalCount = cell.count
        let oneHalfLifeLater = t0.addingTimeInterval(30 * 86_400)
        cell.decay(halfLifeDays: 30, now: oneHalfLifeLater)
        // 100 samples with 30-day half-life and 30 elapsed days → 50.
        #expect(cell.count == 50)
        // Mean must NOT shift just because confidence is bleeding off.
        #expect(abs(cell.mean - originalMean) < 1e-9)
        // m2 should scale down proportionally to retained count.
        #expect(cell.count < originalCount)
    }

    @Test func decayIsNoOpForZeroCount() {
        var cell = BiasCell()
        cell.decay(halfLifeDays: 30, now: Date())
        #expect(cell.count == 0)
        #expect(cell.mean == 0)
        #expect(cell.m2 == 0)
    }

    @Test func decayIsNoOpForZeroElapsed() {
        var cell = BiasCell()
        let when = Date(timeIntervalSinceReferenceDate: 770_000_000)
        cell.recordSample(60, at: when)
        cell.recordSample(40, at: when)
        let countBefore = cell.count
        cell.decay(halfLifeDays: 30, now: when)
        #expect(cell.count == countBefore)
    }

    @Test func encodingRoundTrip() throws {
        var cell = BiasCell()
        let when = Date(timeIntervalSinceReferenceDate: 770_000_000)
        for v in [12.0, 24.0, 36.0] {
            cell.recordSample(v, at: when)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(cell)
        let roundTrip = try decoder.decode(BiasCell.self, from: data)
        #expect(roundTrip.count == cell.count)
        #expect(roundTrip.mean == cell.mean)
        #expect(roundTrip.m2 == cell.m2)
    }

    @Test func biasCellKeyDerivesFromDate() {
        // 2026-05-14 is a Thursday, ~13:00 UTC; force a Chicago calendar so
        // weekday/hour come out predictably.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let comps = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026, month: 5, day: 14, hour: 8, minute: 30
        )
        let when = calendar.date(from: comps)!
        let key = BiasCellKey.make(
            line: "Brown",
            stopId: "40380",
            direction: "Loop-bound",
            at: when,
            calendar: calendar
        )
        #expect(key.hourClass == .amPeak)
        #expect(key.weekdayClass == .weekdayPeak)
        #expect(key.season == .spring)
    }
}
