import Foundation
import Testing
import TransitCache
import TransitModels
@testable import TransitDomain

@Suite("ImminentVehicleResolver")
struct ImminentVehicleResolverTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
    private static let belmont = (stationID: 41320, stopID: 30255)

    /// Stub that always returns the same number of seconds. Mirrors
    /// the v0 shape of `SnapshotWalkingDistanceReader`.
    private struct ConstantWalker: WalkingDistanceReader {
        let seconds: TimeInterval?
        func walkSeconds(
            from origin: (lat: Double, lon: Double),
            to destination: TransitStopRef
        ) -> TimeInterval? { seconds }
    }

    private func brownLineLeg(
        from stop: TransitStopRef = .lStation(belmont.stationID),
        to toStop: TransitStopRef = .lStation(40380)
    ) -> RouteOptionLeg {
        RouteOptionLeg(
            mode: .transit,
            transit: TransitLegInfo(rawName: "Brown Line", resolution: .line(.brown)),
            fromStopID: stop,
            toStopID: toStop,
            approximateDistanceMeters: 6_400
        )
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

    private func bus(
        route: String = "22",
        stopID: Int = 1234,
        vehicleID: String,
        directionName: String = "Northbound",
        minutesFromNow: Double
    ) -> BusPrediction {
        let arrivalAt = Self.now.addingTimeInterval(minutesFromNow * 60)
        return BusPrediction(
            id: "\(vehicleID)-\(stopID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            route: route,
            routeName: "\(directionName) \(route)",
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

    private func portfolioSnapshot(
        trainArrivals: [Arrival] = [],
        busPredictions: [BusPrediction] = [],
        walker: any WalkingDistanceReader = EmptyWalkingDistanceReader(),
        userAt: PlannerCoordinate? = PlannerCoordinate(latitude: 41.95, longitude: -87.66)
    ) -> PortfolioSnapshot {
        PortfolioSnapshot(
            snapshot: TransitSnapshot(
                trainArrivals: trainArrivals,
                busPredictions: busPredictions
            ),
            now: Self.now,
            userLocation: userAt,
            walkingDistance: walker,
            biasCorrection: EmptyBiasCorrectionReader()
        )
    }

    // MARK: - Required test list from the plan

    @Test func picks_earliest_catchable_train() {
        // Walk is 4 min. Two trains: 4 min and 9 min. The 4-min train
        // has 0-min margin — below the default `walkBufferSeconds = 60`
        // floor, so it's filtered out. The 9-min train passes with a
        // 5-min margin.
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 4),
                arrival(runNumber: "405", minutesFromNow: 9),
            ],
            walker: ConstantWalker(seconds: 240)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        #expect(match != nil)
        if case .train(let arrival) = match?.arrival {
            #expect(arrival.runNumber == "405")
        } else {
            Issue.record("expected train, got \(String(describing: match?.arrival))")
        }
        #expect(match?.walkSecondsToStop == 240)
        // 9*60 - 240 = 300
        #expect(match?.catchMarginSeconds == 300)
    }

    @Test func skips_uncatchable_when_walk_distance_too_far() {
        // Walk is 10 min, both trains within 5 min → both uncatchable.
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 2),
                arrival(runNumber: "405", minutesFromNow: 4),
            ],
            walker: ConstantWalker(seconds: 600)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        #expect(match == nil)
    }

    @Test func falls_back_to_next_when_first_uncatchable() {
        // Walk is 5 min. First train at 4 min (uncatchable), second at
        // 12 min (7-min margin, catchable).
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [
                arrival(runNumber: "401", minutesFromNow: 4),
                arrival(runNumber: "405", minutesFromNow: 12),
            ],
            walker: ConstantWalker(seconds: 300)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        if case .train(let arrival) = match?.arrival {
            #expect(arrival.runNumber == "405")
        } else {
            Issue.record("expected fallback train, got \(String(describing: match?.arrival))")
        }
    }

    @Test func returns_nil_when_no_arrivals_in_horizon() {
        // 45-min default horizon; only arrival is at 60 min.
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 60)],
            walker: ConstantWalker(seconds: 120)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        #expect(match == nil)
    }

    // MARK: - Identity matching

    @Test func excludes_different_line_at_same_station() {
        // Belmont serves Red, Brown, Purple. A Red Line arrival at
        // Belmont must not match a Brown Line leg.
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [
                arrival(line: .red, runNumber: "200", minutesFromNow: 4),
                arrival(line: .brown, runNumber: "401", minutesFromNow: 9),
            ],
            walker: ConstantWalker(seconds: 60)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        if case .train(let arrival) = match?.arrival {
            #expect(arrival.line == .brown)
            #expect(arrival.runNumber == "401")
        } else {
            Issue.record("expected Brown Line arrival")
        }
    }

    @Test func excludes_correct_line_at_different_station() {
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [
                arrival(stationID: 99999, runNumber: "200", minutesFromNow: 4),
                arrival(runNumber: "401", minutesFromNow: 9),
            ],
            walker: ConstantWalker(seconds: 60)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        if case .train(let arrival) = match?.arrival {
            #expect(arrival.stationId == Self.belmont.stationID)
            #expect(arrival.runNumber == "401")
        } else {
            Issue.record("expected arrival at Belmont")
        }
    }

    @Test func bus_lookup_filters_by_route_and_stop() {
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            busPredictions: [
                bus(route: "9", vehicleID: "1000", minutesFromNow: 4),
                bus(route: "22", stopID: 9999, vehicleID: "2000", minutesFromNow: 4),
                bus(route: "22", stopID: 1234, vehicleID: "3000", minutesFromNow: 7),
            ],
            walker: ConstantWalker(seconds: 60)
        )
        let leg = RouteOptionLeg(
            mode: .transit,
            transit: TransitLegInfo(rawName: "22 Clark", resolution: .bus("22")),
            fromStopID: .bus(1234),
            toStopID: .bus(1235),
            approximateDistanceMeters: 2_400
        )

        let match = resolver.resolve(firstTransitLeg: leg, snapshot: snapshot)
        if case .bus(let prediction) = match?.arrival {
            #expect(prediction.route == "22")
            #expect(prediction.stopId == 1234)
            #expect(prediction.vehicleId == "3000")
        } else {
            Issue.record("expected route 22 at stop 1234")
        }
    }

    // MARK: - Edge cases

    @Test func returns_nil_for_walking_only_leg() {
        let resolver = ImminentVehicleResolver()
        let leg = RouteOptionLeg(
            mode: .walking,
            approximateDistanceMeters: 1_500
        )
        let snapshot = portfolioSnapshot()
        #expect(resolver.resolve(firstTransitLeg: leg, snapshot: snapshot) == nil)
    }

    @Test func unknown_walk_time_skips_catchability_filter() {
        // Walker returns nil — resolver picks the earliest arrival
        // without filtering, and reports walkSecondsToStop = 0.
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 1)],
            walker: ConstantWalker(seconds: nil)
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        #expect(match != nil)
        #expect(match?.walkSecondsToStop == 0)
        // 1*60 - 0 = 60
        #expect(match?.catchMarginSeconds == 60)
    }

    @Test func no_user_location_uses_zero_walk() {
        let resolver = ImminentVehicleResolver()
        let snapshot = portfolioSnapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 4)],
            walker: ConstantWalker(seconds: 999),
            userAt: nil
        )

        let match = resolver.resolve(firstTransitLeg: brownLineLeg(), snapshot: snapshot)
        // Even though walker would say 999s, no user location means
        // we never call it → walkSecondsToStop = 0.
        #expect(match?.walkSecondsToStop == 0)
    }

    @Test func resolved_arrival_exposes_bias_ref_for_train() {
        let a = arrival(runNumber: "401", minutesFromNow: 4)
        let resolved = ResolvedArrival.train(a)
        if case .train(let line, let stopID, let direction) = resolved.biasRef {
            #expect(line == .brown)
            #expect(stopID == Self.belmont.stopID)
            #expect(direction == "5")
        } else {
            Issue.record("expected train BiasArrivalRef")
        }
    }

    @Test func resolved_arrival_returns_nil_bias_ref_for_metra_and_intercampus() {
        let metra = MetraPrediction(
            id: "x", routeId: "UP-N", routeShortName: "UP-N",
            tripId: "UPN_001", trainNumber: "100",
            stationId: "DAVIS", stationName: "Davis",
            destinationName: "Chicago", directionId: 1,
            generatedAt: Self.now, scheduledAt: Self.now, arrivalAt: Self.now,
            delaySeconds: nil, isDelayed: false, isCanceled: false, isScheduled: false
        )
        #expect(ResolvedArrival.metra(metra).biasRef == nil)

        let inter = IntercampusArrival(
            id: "y", routeId: "icr-s", direction: .southbound,
            tripId: "ICR_001", vehicleId: nil, vehicleLabel: nil,
            stopId: "evanston", stopName: "Evanston Davis",
            destinationName: "Chicago", generatedAt: Self.now, arrivalAt: Self.now,
            delaySeconds: nil, isDelayed: false
        )
        #expect(ResolvedArrival.intercampus(inter).biasRef == nil)
    }

    @Test func firstTransitLeg_returns_nil_for_walking_only_option() {
        let walking = RouteOption(
            label: "Walk it",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: 1_200)]
        )
        #expect(walking.firstTransitLeg == nil)
    }

    @Test func firstTransitLeg_skips_leading_walking_leg() {
        let option = RouteOption(
            label: "Brown",
            legs: [
                RouteOptionLeg(mode: .walking, approximateDistanceMeters: 320),
                brownLineLeg(),
            ]
        )
        #expect(option.firstTransitLeg?.mode == .transit)
        if case .line(let line) = option.firstTransitLeg?.transit?.resolution {
            #expect(line == .brown)
        } else {
            Issue.record("expected Brown Line transit leg")
        }
    }
}
