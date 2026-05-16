import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("StopArrivalProcess")
struct StopArrivalProcessTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func departures(_ minutesAhead: [Double], scheduledFlags: [Bool] = []) -> [LiveDeparture] {
        minutesAhead.enumerated().map { idx, m in
            LiveDeparture(
                arrivalAt: Self.t0.addingTimeInterval(m * 60),
                isApproaching: false,
                isScheduled: idx < scheduledFlags.count ? scheduledFlags[idx] : false
            )
        }
    }

    @Test func normalHeadwaysProduceAcceptableWait() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: departures([5, 13, 21, 29])
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .acceptableWait)
        #expect(forecast.nextDepartureAt == Self.t0.addingTimeInterval(5 * 60))
    }

    @Test func approachingDepartureGivesGoodWait() {
        let approaching = LiveDeparture(
            arrivalAt: Self.t0.addingTimeInterval(120),
            isApproaching: true
        )
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: [approaching, LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(8 * 60))]
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .goodWait)
    }

    @Test func longGapProducesBadGapClassification() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: departures([18, 28, 38, 48])
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .badGap)
    }

    @Test func bunchedFirstGapClassifiesAsBunched() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: departures([8, 11, 22, 32])
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .bunched)
    }

    @Test func staleFeedFallsBackToFeedUnreliable() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: departures([5, 13]),
            scheduleHeadwaySeconds: 480,
            feedState: .stale
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .feedUnreliable)
        #expect(forecast.nextDepartureAt == nil)
    }

    @Test func missingFeedWithSchedulePriorReturnsUnreliable() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: [],
            scheduleHeadwaySeconds: 600,
            feedState: .missing
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .feedUnreliable)
    }

    @Test func missingFeedWithoutScheduleIsUnknown() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: [],
            scheduleHeadwaySeconds: nil,
            feedState: .missing
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.state == .unknown)
    }

    @Test func scheduleFallbackProducesNonZeroBoardProbabilities() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: [],
            scheduleHeadwaySeconds: 600,
            feedState: .missing
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.pBoardWithin15Min > 0)
    }

    @Test func boardWithin5MinFlagsImmediateDeparture() {
        let process = StopArrivalProcess(
            route: "Red",
            generatedAt: Self.t0,
            departures: departures([2, 12, 22])
        )
        let forecast = process.waitDistribution(arrivingAt: Self.t0)
        #expect(forecast.pBoardWithin5Min == 1)
        #expect(forecast.pBoardWithin10Min == 1)
    }
}
