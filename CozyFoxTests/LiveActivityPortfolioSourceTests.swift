import Foundation
import Testing
import TransitCache
import TransitDomain
import TransitModels
@testable import CozyFox

@Suite("LiveActivityCoordinator portfolio source resolution")
struct LiveActivityPortfolioSourceTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
    private static let belmont = (stationID: 41320, stopID: 30255)

    // MARK: - Fixtures

    private static let coordinator = LiveActivityCoordinator()

    private static func arrival(
        line: LineColor = .brown,
        stationID: Int = belmont.stationID,
        stationName: String = "Belmont",
        stopID: Int = belmont.stopID,
        destination: String = "Loop",
        runNumber: String,
        minutesFromNow: Double
    ) -> Arrival {
        let arrivalAt = now.addingTimeInterval(minutesFromNow * 60)
        return Arrival(
            id: "\(runNumber)-\(stationID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            line: line,
            runNumber: runNumber,
            destinationName: destination,
            stationId: stationID,
            stationName: stationName,
            stopId: stopID,
            directionCode: "5",
            predictedAt: now,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private static func bus(
        route: String,
        stopID: Int,
        stopName: String,
        directionName: String,
        destination: String,
        vehicleID: String,
        minutesFromNow: Double
    ) -> BusPrediction {
        let arrivalAt = now.addingTimeInterval(minutesFromNow * 60)
        return BusPrediction(
            id: "\(vehicleID)-\(stopID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            route: route,
            routeName: "\(route) \(directionName)",
            vehicleId: vehicleID,
            stopId: stopID,
            stopName: stopName,
            destinationName: destination,
            directionName: directionName,
            generatedAt: now,
            arrivalAt: arrivalAt,
            isDelayed: false,
            isApproaching: false
        )
    }

    private static func brownLineOption(
        id: UUID = UUID(),
        boardStationID: Int = belmont.stationID
    ) -> RouteOption {
        RouteOption(
            id: id,
            label: "Brown via Belmont",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown Line", resolution: .line(.brown)),
                    fromStopID: .lStation(boardStationID),
                    toStopID: .lStation(40380),
                    approximateDistanceMeters: 6_400
                )
            ]
        )
    }

    private static func busOption(
        id: UUID = UUID(),
        route: String = "22",
        stopID: Int = 1234
    ) -> RouteOption {
        RouteOption(
            id: id,
            label: "\(route) at stop \(stopID)",
            role: .fallback,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Route \(route)", resolution: .bus(route)),
                    fromStopID: .bus(stopID),
                    toStopID: .bus(stopID + 1),
                    approximateDistanceMeters: 4_800
                )
            ]
        )
    }

    private static func recommendation(
        for optionID: UUID,
        changedAt: Date = now,
        missCost: MissCostResult? = nil
    ) -> PortfolioRecommendation {
        PortfolioRecommendation(
            optionID: optionID,
            missCost: missCost,
            changedAt: changedAt,
            lowConfidence: false
        )
    }

    // MARK: - Tests

    @Test func no_portfolios_yields_nil_source() {
        let prefs = UserRoutePreferences.empty
        let result = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: [:],
            snapshot: .empty
        )
        #expect(result == nil)
    }

    @Test func portfolio_with_no_recommendation_yields_nil_source() {
        let option = Self.brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let result = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: [:],
            snapshot: .empty
        )
        #expect(result == nil)
    }

    @Test func train_only_portfolio_resolves_to_train_leg() {
        let option = Self.brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let snapshot = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 6)]
        )

        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        #expect(source?.portfolioID == portfolio.id)
        #expect(source?.optionID == option.id)
        #expect(source?.train?.lineColorRaw == "brown")
        #expect(source?.train?.stopName == "Belmont")
        #expect(source?.bus == nil)
    }

    @Test func bus_only_portfolio_resolves_to_bus_leg() {
        let option = Self.busOption(route: "22", stopID: 1234)
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let snapshot = TransitSnapshot(
            busPredictions: [Self.bus(
                route: "22",
                stopID: 1234,
                stopName: "Clark & Belmont",
                directionName: "Northbound",
                destination: "Howard",
                vehicleID: "1000",
                minutesFromNow: 7
            )]
        )

        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        #expect(source?.train == nil)
        #expect(source?.bus?.routeLabel == "Route 22")
        #expect(source?.bus?.stopName == "Clark & Belmont")
        #expect(source?.bus?.directionLabel == "Northbound")
    }

    @Test func option_with_no_matching_arrivals_falls_through_to_nil() {
        // Portfolio has a Brown Line option, but the snapshot has only
        // Red Line arrivals. Resolver returns nil → coordinator falls
        // back to single-pin source.
        let option = Self.brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let snapshot = TransitSnapshot(
            trainArrivals: [Self.arrival(line: .red, runNumber: "401", minutesFromNow: 6)]
        )

        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        #expect(source == nil)
    }

    @Test func recommendation_pointing_to_missing_option_returns_nil() {
        // Recommendation references an option id no longer present in
        // the portfolio (e.g. user edited the portfolio mid-tick).
        // Resolver skips it.
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [Self.brownLineOption()]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        // Recommendation for a different (deleted) option id.
        let recs = [portfolio.id: Self.recommendation(for: UUID())]
        let snapshot = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 6)]
        )
        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        #expect(source == nil)
    }

    @Test func multi_transit_leg_option_surfaces_first_leg_per_mode() {
        // Brown Line → walking transfer → bus 22. Resolver should
        // produce both a train leg (Brown) and a bus leg (22).
        let option = RouteOption(
            label: "Brown to 22",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown Line", resolution: .line(.brown)),
                    fromStopID: .lStation(Self.belmont.stationID),
                    toStopID: .lStation(40380),
                    approximateDistanceMeters: 4_000
                ),
                RouteOptionLeg(
                    mode: .walking,
                    fromStopID: .lStation(40380),
                    toStopID: .bus(2000),
                    approximateDistanceMeters: 200
                ),
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Route 22", resolution: .bus("22")),
                    fromStopID: .bus(2000),
                    toStopID: .bus(2001),
                    approximateDistanceMeters: 3_500
                ),
            ]
        )
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let snapshot = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 5)],
            busPredictions: [Self.bus(
                route: "22",
                stopID: 2000,
                stopName: "Stop",
                directionName: "Northbound",
                destination: "Terminal",
                vehicleID: "2000",
                minutesFromNow: 12
            )]
        )
        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        #expect(source?.train?.lineColorRaw == "brown")
        #expect(source?.bus?.routeLabel == "Route 22")
    }

    @Test func walking_only_option_resolves_to_nil_source() {
        // No transit legs → no Live Activity source. Coordinator
        // falls back to single-pin / planned-trip-pin.
        let option = RouteOption(
            label: "Walk it",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: 800)]
        )
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: .empty
        )
        #expect(source == nil)
    }

    @Test func train_leg_picks_earliest_future_arrival() {
        // Three arrivals: 2 min, 5 min, 10 min. nextArrival = 2 min,
        // followingArrival = 5 min, upcomingArrivals contains all
        // three.
        let option = Self.brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [portfolio]
        let recs = [portfolio.id: Self.recommendation(for: option.id)]
        let snapshot = TransitSnapshot(
            trainArrivals: [
                Self.arrival(runNumber: "401", minutesFromNow: 2),
                Self.arrival(runNumber: "402", minutesFromNow: 5),
                Self.arrival(runNumber: "403", minutesFromNow: 10),
                Self.arrival(line: .red, runNumber: "200", minutesFromNow: 1),  // wrong line; excluded
            ]
        )
        let source = Self.coordinator.resolvePortfolioSource(
            prefs: prefs,
            recommendations: recs,
            snapshot: snapshot
        )
        guard let train = source?.train else {
            Issue.record("expected train leg")
            return
        }
        #expect(train.nextArrival == Self.now.addingTimeInterval(120))
        #expect(train.followingArrival == Self.now.addingTimeInterval(300))
        #expect(train.upcomingArrivals.count == 3)
    }
}
