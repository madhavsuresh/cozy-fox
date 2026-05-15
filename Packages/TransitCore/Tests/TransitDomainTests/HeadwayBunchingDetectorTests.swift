import Foundation
import Testing
@testable import TransitDomain

@Suite("HeadwayBunchingDetector")
struct HeadwayBunchingDetectorTests {
    private let detector = HeadwayBunchingDetector()
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func arrivals(_ minutesFromNow: [Double]) -> [Date] {
        minutesFromNow.map { Self.t0.addingTimeInterval($0 * 60) }
    }

    // MARK: - Positive cases

    @Test func obviousBunchingIsDetected() {
        // 8m, 11m, 22m, 32m → first gap = 3m, subsequent gaps = 11m, 10m.
        // 3m < 0.5 * 10.5m median ✓, 3m <= 4m floor ✓, 4 arrivals ✓.
        let hint = detector.detect(arrivalTimes: arrivals([8, 11, 22, 32]))
        #expect(hint != nil)
        #expect(abs((hint?.nextArrivalAfterSeconds ?? 0) - 180) < 1e-9)
        #expect(hint?.minutes == 3)
    }

    @Test func tightBunchingRoundsToOneMinute() {
        // Edge: 5m, 6m (60s gap), then 16m, 26m. Median = 10m.
        // 60s < 5m * 0.5 ✓; 60s <= 4m floor ✓.
        let hint = detector.detect(arrivalTimes: arrivals([5, 6, 16, 26]))
        #expect(hint?.minutes == 1)
    }

    // MARK: - Negative cases

    @Test func tooFewArrivalsReturnsNil() {
        // 3 arrivals → only 2 gaps → can't compute median of "subsequent".
        #expect(detector.detect(arrivalTimes: arrivals([8, 11, 22])) == nil)
    }

    @Test func uniformGapsReturnNil() {
        // All 10-min gaps — no bunching.
        #expect(detector.detect(arrivalTimes: arrivals([8, 18, 28, 38])) == nil)
    }

    @Test func slightlyShorterFirstGapStaysBelowRatio() {
        // 8m, 14m, 25m, 36m → first gap = 6m, median subsequent = 11m.
        // 6m / 11m = 0.55, > 0.5 ratio → not bunched.
        #expect(detector.detect(arrivalTimes: arrivals([8, 14, 25, 36])) == nil)
    }

    @Test func firstGapAboveAbsoluteFloorReturnsNil() {
        // 8m, 13m, 26m, 39m → first gap = 5m, median = 13m.
        // 5m < 0.5 * 13m = 6.5m ✓ ratio gate passes.
        // But 5m > 4m absolute floor → returns nil. We don't flag
        // bunching when the "next" train is still 5+ minutes off; the
        // user isn't going to sprint for a 5-min gap.
        #expect(detector.detect(arrivalTimes: arrivals([8, 13, 26, 39])) == nil)
    }

    @Test func customAbsoluteFloorRaisesTheBar() {
        // Same input as above; custom floor at 6m lets it through.
        let hint = detector.detect(
            arrivalTimes: arrivals([8, 13, 26, 39]),
            absoluteFloorSeconds: 6 * 60
        )
        #expect(hint != nil)
        #expect(hint?.minutes == 5)
    }

    @Test func customRatioLetsLooserBunchingThrough() {
        // Arrivals at 0, 3, 8, 13 → gaps [3m, 5m, 5m].
        // First gap 3m = 180s; median subsequent = 300s.
        // Default ratio 0.5: 180 < 150? No → default fails.
        // Custom ratio 0.7: 180 < 210? Yes → flagged.
        // Floor check: 180s <= 240s ✓.
        let times = arrivals([0, 3, 8, 13])
        #expect(detector.detect(arrivalTimes: times) == nil)
        let hint = detector.detect(arrivalTimes: times, bunchingRatio: 0.7)
        #expect(hint != nil)
        #expect(hint?.minutes == 3)
    }

    @Test func zeroOrNegativeFirstGapReturnsNil() {
        // Two arrivals share a timestamp — gap = 0. Don't flag.
        var times = arrivals([8, 18, 28, 38])
        times[1] = times[0]
        #expect(detector.detect(arrivalTimes: times) == nil)
    }

    @Test func sortsArrivalsBeforeComputingGaps() {
        // Reverse order — detector should still find the bunching.
        let hint = detector.detect(arrivalTimes: arrivals([32, 22, 11, 8]))
        #expect(hint != nil)
        #expect(hint?.minutes == 3)
    }

    @Test func minimumArrivalsParameterIsRespected() {
        // 3 arrivals with bunching — default refuses, but a custom
        // minimumArrivals=3 lets it through (caller's call).
        let times = arrivals([8, 11, 22])
        #expect(detector.detect(arrivalTimes: times) == nil)
        let hint = detector.detect(arrivalTimes: times, minimumArrivals: 3)
        // 2 gaps total: gap[0]=3m, gap[1]=11m. subsequent=[11], median=11.
        // 3m < 0.5*11 = 5.5 ✓, 3m <= 4m ✓.
        #expect(hint != nil)
        #expect(hint?.minutes == 3)
    }
}
