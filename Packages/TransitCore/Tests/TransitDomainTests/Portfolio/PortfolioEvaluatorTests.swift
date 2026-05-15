import Foundation
import Testing
import TransitCache
import TransitModels
@testable import TransitDomain

@Suite("PortfolioEvaluator")
struct PortfolioEvaluatorTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
    private static let belmont = (stationID: 41320, stopID: 30255)
    private static let southport = (stationID: 41440, stopID: 30074)

    private struct ConstantWalker: WalkingDistanceReader {
        let seconds: TimeInterval?
        func walkSeconds(
            from origin: (lat: Double, lon: Double),
            to destination: TransitStopRef
        ) -> TimeInterval? { seconds }
    }

    private func arrival(
        line: LineColor = .brown,
        stationID: Int = belmont.stationID,
        stopID: Int = belmont.stopID,
        runNumber: String,
        minutesFromNow: Double
    ) -> Arrival {
        let arrivalAt = Self.now.addingTimeInterval(minutesFromNow * 60)
        return Arrival(
            id: "\(runNumber)-\(stationID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            line: line,
            runNumber: runNumber,
            destinationName: "Loop",
            stationId: stationID,
            stationName: "Belmont",
            stopId: stopID,
            directionCode: "5",
            predictedAt: Self.now,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private func brownLineOption(
        id: UUID = UUID(),
        boardStationID: Int = belmont.stationID,
        alightStationID: Int = southport.stationID,
        meters: Double = 6_400
    ) -> RouteOption {
        RouteOption(
            id: id,
            label: "Brown",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown", resolution: .line(.brown)),
                    fromStopID: .lStation(boardStationID),
                    toStopID: .lStation(alightStationID),
                    approximateDistanceMeters: meters
                )
            ]
        )
    }

    private func walkingOption(id: UUID = UUID(), meters: Double = 1_500) -> RouteOption {
        RouteOption(
            id: id,
            label: "Walk",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: meters)]
        )
    }

    private func snapshot(
        trainArrivals: [Arrival] = [],
        walker: any WalkingDistanceReader = ConstantWalker(seconds: 60)
    ) -> PortfolioSnapshot {
        PortfolioSnapshot(
            snapshot: TransitSnapshot(trainArrivals: trainArrivals),
            now: Self.now,
            userLocation: PlannerCoordinate(latitude: 41.95, longitude: -87.66),
            walkingDistance: walker,
            biasCorrection: EmptyBiasCorrectionReader()
        )
    }

    // MARK: - Tests

    @Test func returns_evaluations_for_every_option() {
        let evaluator = PortfolioEvaluator()
        let a = brownLineOption()
        let b = walkingOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [a, b]
        )
        let s = snapshot(trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)])

        let result = evaluator.evaluate(portfolio: portfolio, snapshot: s)
        #expect(result.portfolioID == portfolio.id)
        #expect(result.evaluations.count == 2)
        #expect(Set(result.evaluations.map(\.optionID)) == Set([a.id, b.id]))
        // Scores keyed by option id, covers every option.
        #expect(Set(result.scores.keys) == Set([a.id, b.id]))
    }

    @Test func recommended_option_is_argmax_of_available() {
        // Two transit options. The faster (Brown Line at 5 min) wins
        // over the slower (Brown Line at 15 min).
        let evaluator = PortfolioEvaluator()
        let fast = brownLineOption(boardStationID: Self.belmont.stationID)
        let slow = brownLineOption(boardStationID: Self.southport.stationID)
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [slow, fast]  // intentionally inverted to test argmax
        )
        let s = snapshot(
            trainArrivals: [
                arrival(stationID: Self.belmont.stationID, runNumber: "401", minutesFromNow: 5),
                arrival(stationID: Self.southport.stationID, runNumber: "405", minutesFromNow: 15),
            ]
        )
        let result = evaluator.evaluate(portfolio: portfolio, snapshot: s)
        #expect(result.recommendedOptionID == fast.id)
    }

    @Test func unavailable_options_are_skipped_in_argmax() {
        // Brown Line has no arrivals (unavailable). Walking option is
        // long but available. Walking should win.
        let evaluator = PortfolioEvaluator()
        let train = brownLineOption()
        let walk = walkingOption(meters: 600) // ~7 min
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [train, walk]
        )
        let s = snapshot()  // no arrivals
        let result = evaluator.evaluate(portfolio: portfolio, snapshot: s)
        #expect(result.recommendedOptionID == walk.id)
    }

    @Test func empty_portfolio_returns_no_recommendation() {
        let evaluator = PortfolioEvaluator()
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: []
        )
        let result = evaluator.evaluate(portfolio: portfolio, snapshot: snapshot())
        #expect(result.recommendedOptionID == nil)
        #expect(result.evaluations.isEmpty)
        #expect(result.scores.isEmpty)
    }

    @Test func all_unavailable_returns_no_recommendation() {
        let evaluator = PortfolioEvaluator()
        // Single train option, no arrivals → unavailable.
        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let result = evaluator.evaluate(portfolio: portfolio, snapshot: snapshot())
        #expect(result.recommendedOptionID == nil)
        // The unavailable option is still in evaluations + scores.
        #expect(result.evaluations.count == 1)
        #expect(result.scores[option.id] == .greatestFiniteMagnitude)
    }

    @Test func evaluation_lookup_helper_returns_match() {
        let evaluator = PortfolioEvaluator()
        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let result = evaluator.evaluate(
            portfolio: portfolio,
            snapshot: snapshot(trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)])
        )
        #expect(result.evaluation(for: option.id)?.optionID == option.id)
        #expect(result.evaluation(for: UUID()) == nil)
    }
}
