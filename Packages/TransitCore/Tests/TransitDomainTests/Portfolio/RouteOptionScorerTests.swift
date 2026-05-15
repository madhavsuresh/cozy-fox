import Foundation
import Testing
import TransitCache
import TransitModels
@testable import TransitDomain

@Suite("RouteOptionScorer")
struct RouteOptionScorerTests {
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

    private struct FixedBiasReader: BiasCorrectionReader {
        let correction: ArrivalBiasCorrection?
        func correction(for arrival: BiasArrivalRef, at when: Date) -> ArrivalBiasCorrection? {
            correction
        }
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
        alightStationID: Int = southport.stationID
    ) -> RouteOption {
        RouteOption(
            id: id,
            label: "Brown",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .walking,
                    fromStopID: nil,
                    toStopID: .lStation(boardStationID),
                    approximateDistanceMeters: 320
                ),
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown Line", resolution: .line(.brown)),
                    fromStopID: .lStation(boardStationID),
                    toStopID: .lStation(alightStationID),
                    approximateDistanceMeters: 6_400
                ),
            ]
        )
    }

    private func walkingOnlyOption(id: UUID = UUID(), meters: Double = 1_200) -> RouteOption {
        RouteOption(
            id: id,
            label: "Walk",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: meters)]
        )
    }

    private func snapshot(
        trainArrivals: [Arrival] = [],
        userAt: PlannerCoordinate? = PlannerCoordinate(latitude: 41.95, longitude: -87.66),
        walker: any WalkingDistanceReader = ConstantWalker(seconds: 120),
        bias: any BiasCorrectionReader = EmptyBiasCorrectionReader(),
        closedStationIDs: Set<Int> = []
    ) -> PortfolioSnapshot {
        PortfolioSnapshot(
            snapshot: TransitSnapshot(trainArrivals: trainArrivals),
            now: Self.now,
            userLocation: userAt,
            walkingDistance: walker,
            biasCorrection: bias,
            closedStationIDs: closedStationIDs
        )
    }

    // MARK: - Required test list

    @Test func score_orders_by_eta_with_default_weights() {
        // Two options identical except for board station. The one with
        // the earlier first-leg arrival should sort first under
        // `ETAWeights.etaOnly`.
        let scorer = RouteOptionScorer()
        let early = brownLineOption(boardStationID: 41320)
        let late = brownLineOption(boardStationID: 41440)

        let s = snapshot(
            trainArrivals: [
                arrival(stationID: 41320, runNumber: "401", minutesFromNow: 5),
                arrival(stationID: 41440, runNumber: "405", minutesFromNow: 15),
            ]
        )
        let earlyEval = scorer.evaluate(option: early, snapshot: s)
        let lateEval = scorer.evaluate(option: late, snapshot: s)

        let earlyScore = scorer.score(earlyEval, now: s.now, weights: .etaOnly)
        let lateScore = scorer.score(lateEval, now: s.now, weights: .etaOnly)
        #expect(earlyScore < lateScore)
    }

    @Test func high_variance_route_penalized_when_lambdaVar_positive() {
        let scorer = RouteOptionScorer()
        let lowVarianceEval = RouteEvaluation(
            optionID: UUID(),
            available: true,
            etaMedian: Self.now.addingTimeInterval(600),
            etaStdDev: 30,
            pFailure: 0,
            transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 1
        )
        let highVarianceEval = RouteEvaluation(
            optionID: UUID(),
            available: true,
            etaMedian: Self.now.addingTimeInterval(600),
            etaStdDev: 300,
            pFailure: 0,
            transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 1
        )

        let weights = ETAWeights(lambdaVariance: 1.0, lambdaFailure: 0, lambdaTransfer: 0)
        let lowScore = scorer.score(lowVarianceEval, now: Self.now, weights: weights)
        let highScore = scorer.score(highVarianceEval, now: Self.now, weights: weights)
        #expect(highScore > lowScore)
        // Score diff equals weight × σ difference.
        #expect(abs((highScore - lowScore) - 270) < 1e-9)
    }

    @Test func high_failure_route_penalized() {
        let scorer = RouteOptionScorer()
        let safe = RouteEvaluation(
            optionID: UUID(),
            available: true,
            etaMedian: Self.now.addingTimeInterval(600),
            etaStdDev: 0,
            pFailure: 0,
            transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 1
        )
        let risky = RouteEvaluation(
            optionID: UUID(),
            available: true,
            etaMedian: Self.now.addingTimeInterval(600),
            etaStdDev: 0,
            pFailure: 0.5,
            transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 1
        )
        #expect(scorer.score(risky, now: Self.now) > scorer.score(safe, now: Self.now))
    }

    @Test func unavailable_options_sort_last() {
        let scorer = RouteOptionScorer()
        let avail = RouteEvaluation(
            optionID: UUID(),
            available: true,
            etaMedian: Self.now.addingTimeInterval(3600),
            etaStdDev: 0, pFailure: 0, transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 1
        )
        let unavail = RouteEvaluation(
            optionID: UUID(),
            available: false,
            etaMedian: Self.now.addingTimeInterval(120),
            etaStdDev: 0, pFailure: 1, transferCount: 0,
            nextActionDeadline: Self.now,
            confidence: 0,
            unavailableReason: .noArrivalsInHorizon
        )
        #expect(scorer.score(unavail, now: Self.now) > scorer.score(avail, now: Self.now))
        #expect(scorer.score(unavail, now: Self.now) == .greatestFiniteMagnitude)
    }

    // MARK: - Evaluation specifics

    @Test func walking_only_option_eta_is_distance_over_pace() {
        let scorer = RouteOptionScorer()
        let s = snapshot()
        let option = walkingOnlyOption(meters: 840) // ~10 min at 1.4 m/s
        let eval = scorer.evaluate(option: option, snapshot: s)
        #expect(eval.available == true)
        #expect(eval.imminentVehicle == nil)
        #expect(eval.transferCount == 0)
        // 840 / 1.4 = 600
        let etaSeconds = eval.etaMedian.timeIntervalSince(s.now)
        #expect(abs(etaSeconds - 600) < 1e-6)
    }

    @Test func transit_option_eta_uses_imminent_plus_estimated_post_legs() {
        // No bias correction; ETA = arrival.arrivalAt + estimated
        // ride duration (6400m at 11.17 m/s ≈ 573s).
        let scorer = RouteOptionScorer()
        let s = snapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)]
        )
        let option = brownLineOption()
        let eval = scorer.evaluate(option: option, snapshot: s)

        #expect(eval.available == true)
        #expect(eval.imminentVehicle != nil)
        // arrival at 5 min + ~573s ≈ 873s from now
        let etaSeconds = eval.etaMedian.timeIntervalSince(s.now)
        #expect(etaSeconds > 800 && etaSeconds < 900)
    }

    @Test func bias_correction_shifts_eta_in_signed_direction() {
        // apiEarly (positive) — vehicle later than predicted, so add
        // magnitudeSeconds to ETA.
        let scorer = RouteOptionScorer()
        let lateBias = ArrivalBiasCorrection(
            direction: .apiEarly,
            magnitudeSeconds: 120,
            stdDevSeconds: 30
        )
        let earlyBias = ArrivalBiasCorrection(
            direction: .apiLate,
            magnitudeSeconds: 120,
            stdDevSeconds: 30
        )

        func evaluateWith(_ bias: ArrivalBiasCorrection) -> RouteEvaluation {
            let s = snapshot(
                trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)],
                bias: FixedBiasReader(correction: bias)
            )
            return scorer.evaluate(option: brownLineOption(), snapshot: s)
        }

        let later = evaluateWith(lateBias)
        let earlier = evaluateWith(earlyBias)
        // apiEarly pushes ETA out (later), apiLate pulls it in.
        #expect(later.etaMedian > earlier.etaMedian)
        let delta = later.etaMedian.timeIntervalSince(earlier.etaMedian)
        // 2 × 120 = 240
        #expect(abs(delta - 240) < 1e-6)
        // Variance comes through unchanged.
        #expect(later.etaStdDev == 30)
        #expect(earlier.etaStdDev == 30)
    }

    @Test func unknown_walk_time_yields_low_confidence() {
        let scorer = RouteOptionScorer()
        let s = snapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)],
            walker: ConstantWalker(seconds: nil)
        )
        let eval = scorer.evaluate(option: brownLineOption(), snapshot: s)
        #expect(eval.available == true)
        #expect(eval.confidence == 0.5)
    }

    @Test func no_arrivals_in_horizon_marks_unavailable() {
        let scorer = RouteOptionScorer()
        // No train arrivals at all → resolver returns nil → unavailable.
        let s = snapshot(walker: ConstantWalker(seconds: 60))
        let eval = scorer.evaluate(option: brownLineOption(), snapshot: s)
        #expect(eval.available == false)
        if case .noArrivalsInHorizon = eval.unavailableReason {
            // ok
        } else {
            Issue.record("expected .noArrivalsInHorizon, got \(String(describing: eval.unavailableReason))")
        }
    }

    @Test func closed_station_along_leg_marks_unavailable() {
        let scorer = RouteOptionScorer()
        let s = snapshot(
            trainArrivals: [arrival(runNumber: "401", minutesFromNow: 5)],
            closedStationIDs: [Self.southport.stationID]
        )
        let option = brownLineOption(alightStationID: Self.southport.stationID)
        let eval = scorer.evaluate(option: option, snapshot: s)
        #expect(eval.available == false)
        if case .closedStation(let ids) = eval.unavailableReason {
            #expect(ids == [Self.southport.stationID])
        } else {
            Issue.record("expected .closedStation")
        }
    }

    @Test func transfer_count_excludes_first_transit_leg() {
        // Brown → Red transfer at Belmont: 2 transit legs, 1 transfer.
        let scorer = RouteOptionScorer()
        let option = RouteOption(
            label: "Brown to Red",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown", resolution: .line(.brown)),
                    fromStopID: .lStation(40380),
                    toStopID: .lStation(41320),
                    approximateDistanceMeters: 4_000
                ),
                RouteOptionLeg(
                    mode: .walking,
                    fromStopID: .lStation(41320),
                    toStopID: .lStation(41320),
                    approximateDistanceMeters: 50
                ),
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Red", resolution: .line(.red)),
                    fromStopID: .lStation(41320),
                    toStopID: .lStation(40380),
                    approximateDistanceMeters: 7_000
                ),
            ]
        )
        let s = snapshot(
            trainArrivals: [arrival(stationID: 40380, runNumber: "401", minutesFromNow: 5)]
        )
        let eval = scorer.evaluate(option: option, snapshot: s)
        #expect(eval.transferCount == 1)
    }
}
