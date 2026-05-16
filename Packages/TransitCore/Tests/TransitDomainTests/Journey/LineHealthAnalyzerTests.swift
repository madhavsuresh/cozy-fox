import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("LineHealthAnalyzer")
struct LineHealthAnalyzerTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let analyzer = LineHealthAnalyzer()

    private func arrivals(_ minutesAhead: [Double]) -> [Date] {
        minutesAhead.map { Self.t0.addingTimeInterval($0 * 60) }
    }

    @Test func normalHeadwaysClassifyAsNormal() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([5, 13, 21, 29]),
            baselineHeadwaySeconds: 480,
            feedState: .fresh,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .normal)
    }

    @Test func longGapClassifiesAsLongGap() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([0, 22, 32, 42]),
            baselineHeadwaySeconds: 480,
            feedState: .fresh,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .longGap)
    }

    @Test func bunchedFirstGapClassifiesAsBunchedThenGap() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([0, 3, 14, 25]),
            baselineHeadwaySeconds: 660,
            feedState: .fresh,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .bunchedThenGap)
    }

    @Test func staleFeedClassifiesAsFeedStale() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([5, 13]),
            baselineHeadwaySeconds: 480,
            feedState: .stale,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .feedStale)
    }

    @Test func singleArrivalIsInsufficientData() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([5]),
            baselineHeadwaySeconds: 480,
            feedState: .fresh,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .insufficientData)
    }

    @Test func compressedHeadwaysClassifyAsCompressed() {
        let snapshot = analyzer.analyze(
            route: "Red",
            upcomingArrivals: arrivals([0, 2, 4, 6]),
            baselineHeadwaySeconds: 480,
            feedState: .fresh,
            generatedAt: Self.t0
        )
        #expect(snapshot.state == .compressed)
    }
}
