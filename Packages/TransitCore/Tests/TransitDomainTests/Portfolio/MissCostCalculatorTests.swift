import Foundation
import Testing
import TransitCache
import TransitModels
@testable import TransitDomain

@Suite("MissCostCalculator")
struct MissCostCalculatorTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
    /// Late-night instant in Chicago: 2026-05-14 23:55 → hour ≥ 22 so
    /// `LastTrainSafety.warning(...)` can fire. Used by the
    /// last-train collapse test.
    private static let lateNight: Date = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let comps = DateComponents(
            calendar: c, timeZone: c.timeZone,
            year: 2026, month: 5, day: 14, hour: 23, minute: 55
        )
        return c.date(from: comps)!
    }()

    private static let belmont = (stationID: 41320, stopID: 30255)

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
        from referenceNow: Date = now,
        minutesFromNow: Double
    ) -> Arrival {
        let arrivalAt = referenceNow.addingTimeInterval(minutesFromNow * 60)
        return Arrival(
            id: "\(runNumber)-\(stationID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            line: line,
            runNumber: runNumber,
            destinationName: "Loop",
            stationId: stationID,
            stationName: "Belmont",
            stopId: stopID,
            directionCode: "5",
            predictedAt: referenceNow,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private func bus(
        route: String = "22",
        stopID: Int = 9000,
        vehicleID: String,
        directionName: String = "Northbound",
        minutesFromNow: Double
    ) -> BusPrediction {
        let arrivalAt = Self.now.addingTimeInterval(minutesFromNow * 60)
        return BusPrediction(
            id: "\(vehicleID)-\(stopID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            route: route,
            routeName: "\(route) \(directionName)",
            vehicleId: vehicleID,
            stopId: stopID,
            stopName: "Stop",
            destinationName: "Terminal",
            directionName: directionName,
            generatedAt: Self.now,
            arrivalAt: arrivalAt,
            isDelayed: false,
            isApproaching: false
        )
    }

    private func brownLineOption(id: UUID = UUID()) -> RouteOption {
        RouteOption(
            id: id,
            label: "Brown",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown", resolution: .line(.brown)),
                    fromStopID: .lStation(Self.belmont.stationID),
                    toStopID: .lStation(40380),
                    approximateDistanceMeters: 6_400
                )
            ]
        )
    }

    private func busOption(id: UUID = UUID()) -> RouteOption {
        RouteOption(
            id: id,
            label: "22 Clark",
            role: .fallback,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "22 Clark", resolution: .bus("22")),
                    fromStopID: .bus(9000),
                    toStopID: .bus(9001),
                    approximateDistanceMeters: 5_500
                )
            ]
        )
    }

    private func walkingOption(id: UUID = UUID()) -> RouteOption {
        RouteOption(
            id: id,
            label: "Walk",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: 1_500)]
        )
    }

    private func snapshot(
        now referenceNow: Date = now,
        trainArrivals: [Arrival] = [],
        busPredictions: [BusPrediction] = [],
        walker: any WalkingDistanceReader = ConstantWalker(seconds: 60)
    ) -> PortfolioSnapshot {
        PortfolioSnapshot(
            snapshot: TransitSnapshot(
                trainArrivals: trainArrivals,
                busPredictions: busPredictions
            ),
            now: referenceNow,
            userLocation: PlannerCoordinate(latitude: 41.95, longitude: -87.66),
            walkingDistance: walker,
            biasCorrection: EmptyBiasCorrectionReader()
        )
    }

    // MARK: - Required test list

    @Test func bunched_trains_yield_small_delta() {
        // Two Brown Line trains 3 min apart at the same station →
        // same-route fallback ETA differs by ~3 min.
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let s = snapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 6),
                arrival(runNumber: "402", minutesFromNow: 9),
            ]
        )
        let eval = scorer.evaluate(option: option, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)
        #expect(miss != nil)
        // Both options arrive ~573s after their respective boarding
        // — so delta tracks the boarding-time gap of 3 min.
        if let miss {
            #expect(abs(miss.delta - 180) < 1e-6)
            #expect(miss.fallbackOptionID == option.id)
            #expect(miss.collapses == false)
        }
    }

    @Test func cross_route_fallback_identified_when_bus_beats_next_train() {
        // Brown Line: imminent at 6 min, NEXT at 30 min.
        // Bus 22:    imminent at 8 min — beats the 30-min next train.
        // Miss-cost fallback should be the bus option, not same-route.
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let trainOption = brownLineOption()
        let bussOption = busOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [trainOption, bussOption]
        )
        let s = snapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 6),
                arrival(runNumber: "402", minutesFromNow: 30),
            ],
            busPredictions: [
                bus(vehicleID: "1000", minutesFromNow: 8),
            ]
        )
        let eval = scorer.evaluate(option: trainOption, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)

        #expect(miss != nil)
        // Bus boards 2 min after the missed train, and bus speed
        // estimate (4.5 m/s) yields a longer ride than the L (11.17
        // m/s) — but bus boarding alone is still earlier than the
        // 30-min next train. Verify fallback identity.
        if let miss {
            #expect(miss.fallbackOptionID == bussOption.id)
            #expect(miss.collapses == false)
        }
    }

    @Test func collapses_on_last_train_safety() {
        // Late-night snapshot. Two arrivals: 8 min and 22 min. Both
        // within `LastTrainSafety.warningWindow` (30 min). At hour 23,
        // `LastTrainSafety.warning(...)` fires → collapse flag set.
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let s = snapshot(
            now: Self.lateNight,
            trainArrivals: [
                arrival(runNumber: "401", from: Self.lateNight, minutesFromNow: 8),
                arrival(runNumber: "402", from: Self.lateNight, minutesFromNow: 22),
            ]
        )
        let eval = scorer.evaluate(option: option, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)
        #expect(miss?.collapses == true)
    }

    @Test func returns_nil_for_walk_only_recommended_option() {
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let walking = walkingOption()
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [walking]
        )
        let s = snapshot()
        let eval = scorer.evaluate(option: walking, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)
        #expect(miss == nil)
    }

    @Test func filtered_snapshot_does_not_remove_subsequent_same_route_arrivals() {
        // After removing the imminent arrival, the resolver running
        // again under the filtered snapshot must still find the
        // subsequent arrivals on the same route — that's the same-
        // route fallback.
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let s = snapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 6),
                arrival(runNumber: "402", minutesFromNow: 14),
                arrival(runNumber: "403", minutesFromNow: 22),
            ]
        )
        let eval = scorer.evaluate(option: option, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)
        #expect(miss != nil)
        // The same-route next is the 14-min train (8 min after the
        // missed 6-min train).
        if let miss {
            #expect(abs(miss.delta - 480) < 1e-6)
            #expect(miss.fallbackOptionID == option.id)
        }
    }

    // MARK: - Additional coverage

    @Test func catchability_grades_by_margin() {
        // Margin 60s → 0; 300s → 1; midpoint → 0.5.
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )

        // Walk = 60s, arrival at 6 min → margin = 360 - 60 = 300 → 1.0
        let easySnap = snapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 6),
                arrival(runNumber: "402", minutesFromNow: 14),
            ],
            walker: ConstantWalker(seconds: 60)
        )
        let easyEval = scorer.evaluate(option: option, snapshot: easySnap)
        let easyMiss = calculator.missCost(
            recommended: easyEval,
            portfolio: portfolio,
            snapshot: easySnap
        )
        #expect(easyMiss?.catchability == 1.0)

        // Walk = 240s, arrival at 5 min → margin = 60 → catchability = 0.
        let tightSnap = snapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 5),
                arrival(runNumber: "402", minutesFromNow: 14),
            ],
            walker: ConstantWalker(seconds: 240)
        )
        let tightEval = scorer.evaluate(option: option, snapshot: tightSnap)
        let tightMiss = calculator.missCost(
            recommended: tightEval,
            portfolio: portfolio,
            snapshot: tightSnap
        )
        #expect(tightMiss?.catchability == 0.0)
    }

    @Test func no_fallback_in_horizon_collapses_even_without_last_train() {
        // Single arrival, no other options. After removing the
        // imminent one, nothing's in horizon → collapse without
        // last-train (it's midday in the fixture).
        let scorer = RouteOptionScorer()
        let calculator = MissCostCalculator(scorer: scorer)

        let option = brownLineOption()
        let portfolio = RoutePortfolio(
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [option]
        )
        let s = snapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 6)]
        )
        let eval = scorer.evaluate(option: option, snapshot: s)
        let miss = calculator.missCost(recommended: eval, portfolio: portfolio, snapshot: s)
        #expect(miss != nil)
        #expect(miss?.delta == .infinity)
        #expect(miss?.collapses == true)
        #expect(miss?.etaIfMissed == .distantFuture)
    }
}
