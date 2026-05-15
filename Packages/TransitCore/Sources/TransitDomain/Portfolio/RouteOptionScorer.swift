import Foundation
import TransitCache
import TransitModels

/// Weights for the aggregate score the scorer's `score(_:now:)`
/// produces. The aggregate is "weighted seconds-from-now until you
/// arrive at the destination," so every term has units of seconds and
/// lower is better.
///
/// All defaults are conservative — favoring fast options without
/// over-penalizing variance or transfers. Phase 7's behavior tuning
/// will revisit them once we have real evaluations to ground them in.
public struct ETAWeights: Sendable, Hashable {
    /// Multiplier on `etaStdDev`. `0.5` means "1 minute of additional
    /// σ is worth 30 seconds of additional median ETA." Reflects that
    /// users dislike uncertain options but not nearly as much as slow
    /// ones.
    public let lambdaVariance: Double
    /// Penalty per unit of `pFailure` ∈ [0, 1], in seconds. `600`
    /// means "a coin-flip-failure option pays a 5-minute penalty."
    public let lambdaFailure: Double
    /// Penalty per transfer, in seconds. Each transfer adds friction
    /// — extra waits, walking, missed connection risk — so even when
    /// the modeled ETA is the same, fewer-transfer options should
    /// win.
    public let lambdaTransfer: Double

    public init(
        lambdaVariance: Double = 0.5,
        lambdaFailure: Double = 600,
        lambdaTransfer: Double = 60
    ) {
        self.lambdaVariance = lambdaVariance
        self.lambdaFailure = lambdaFailure
        self.lambdaTransfer = lambdaTransfer
    }

    public static let defaults = ETAWeights()
    /// Weights that ignore variance and failure — useful when tests
    /// want to assert "lower ETA wins, all else equal."
    public static let etaOnly = ETAWeights(
        lambdaVariance: 0,
        lambdaFailure: 0,
        lambdaTransfer: 0
    )
}

/// Mode-specific average ground speeds in m/s. Used to estimate the
/// duration of legs the evaluator can't resolve to a specific vehicle
/// (post-transfer transit legs, walking legs, fallback when bias data
/// is missing). Matches `LocalTransitPlanner`'s defaults so the
/// evaluator's projections are consistent with the planner's.
private enum LegSpeed {
    /// 84 m/min = 1.4 m/s. Same as the dashboard's walking pace.
    static let walking: Double = 1.4
    /// 670 m/min = 11.17 m/s. Closer to L line top-speed than
    /// platform-to-platform; v0 uses one figure rather than
    /// modelling dwell-time per stop.
    static let lTrain: Double = 670.0 / 60.0
    /// 270 m/min = 4.5 m/s. CTA buses including dwell at stops.
    static let bus: Double = 270.0 / 60.0
    /// 900 m/min = 15.0 m/s. Metra line haul (commuter rail averages
    /// higher than urban L due to fewer stops + longer track
    /// segments).
    static let metra: Double = 900.0 / 60.0

    static func estimatedSeconds(for leg: RouteOptionLeg) -> TimeInterval {
        switch leg.mode {
        case .walking:
            return leg.approximateDistanceMeters / walking
        case .transit:
            switch leg.transit?.resolution {
            case .line: return leg.approximateDistanceMeters / lTrain
            case .bus: return leg.approximateDistanceMeters / bus
            case .metra: return leg.approximateDistanceMeters / metra
            case .unknown, .none: return leg.approximateDistanceMeters / bus
            }
        case .other:
            return leg.approximateDistanceMeters / bus
        }
    }
}

/// Produces a `RouteEvaluation` for a single `RouteOption` against a
/// `PortfolioSnapshot`. Pure / `Sendable`. The scorer composes the
/// imminent-vehicle resolver, the leg-duration estimator above, and
/// the bias correction reader — no live data fetching.
public struct RouteOptionScorer: Sendable {
    public let resolver: ImminentVehicleResolver
    public let weights: ETAWeights

    public init(
        resolver: ImminentVehicleResolver = ImminentVehicleResolver(),
        weights: ETAWeights = .defaults
    ) {
        self.resolver = resolver
        self.weights = weights
    }

    // MARK: - Evaluation

    public func evaluate(
        option: RouteOption,
        snapshot: PortfolioSnapshot
    ) -> RouteEvaluation {
        let now = snapshot.now
        let transferCount = max(0, transitLegCount(option) - 1)

        // Closed-station gate. Any leg whose stop touches a closed
        // station marks the option unavailable.
        let touchedClosed = closedStationIDsTouched(option: option, closedIDs: snapshot.closedStationIDs)
        if !touchedClosed.isEmpty {
            let fallbackDeadline = now.addingTimeInterval(totalEstimatedSeconds(option))
            return RouteEvaluation(
                optionID: option.id,
                available: false,
                etaMedian: fallbackDeadline,
                etaStdDev: 0,
                pFailure: 1,
                transferCount: transferCount,
                nextActionDeadline: now,
                confidence: 0,
                imminentVehicle: nil,
                unavailableReason: .closedStation(Array(touchedClosed).sorted())
            )
        }

        // Walking-only options short-circuit: no vehicle, no bias.
        guard let firstTransit = option.firstTransitLeg else {
            let totalSeconds = totalEstimatedSeconds(option)
            let eta = now.addingTimeInterval(totalSeconds)
            return RouteEvaluation(
                optionID: option.id,
                available: true,
                etaMedian: eta,
                etaStdDev: 0,
                pFailure: 0,
                transferCount: 0,
                nextActionDeadline: now,
                confidence: 1,
                imminentVehicle: nil,
                unavailableReason: nil
            )
        }

        // Transit option: resolve the imminent vehicle for the first
        // transit leg.
        guard let match = resolver.resolve(firstTransitLeg: firstTransit, snapshot: snapshot) else {
            // No catchable vehicle in horizon for the first leg.
            let fallback = now.addingTimeInterval(resolver.horizon)
            return RouteEvaluation(
                optionID: option.id,
                available: false,
                etaMedian: fallback,
                etaStdDev: 0,
                pFailure: 1,
                transferCount: transferCount,
                nextActionDeadline: now,
                confidence: 0,
                imminentVehicle: nil,
                unavailableReason: .noArrivalsInHorizon
            )
        }

        // ETA branch: arrival time at board stop + estimated remaining
        // duration after the first transit leg.
        let postFirstLegSeconds = estimatedSecondsAfter(firstTransitLeg: firstTransit, in: option)
        var etaMedian = match.arrival.arrivalAt.addingTimeInterval(postFirstLegSeconds)
        var etaStdDev: TimeInterval = 0

        // Apply bias correction when one exists for this arrival.
        if let biasRef = match.arrival.biasRef,
           let correction = snapshot.biasCorrection.correction(for: biasRef, at: match.arrival.arrivalAt)
        {
            etaMedian = etaMedian.addingTimeInterval(signedMedianSeconds(correction))
            etaStdDev = correction.stdDevSeconds ?? 0
        }

        // Confidence drops when the user's walk time was unknown —
        // the catchability filter was bypassed and we may be
        // surfacing an arrival the user can't actually make. A walk
        // time of `0` comes back when either `userLocation` was nil
        // or the walking cache hadn't populated for this origin × stop
        // pair yet; both cases warrant low confidence.
        let walkKnown = match.walkSecondsToStop > 0
        let confidence = walkKnown ? 1.0 : 0.5

        let nextActionDeadline = match.arrival.arrivalAt
            .addingTimeInterval(-match.walkSecondsToStop)

        return RouteEvaluation(
            optionID: option.id,
            available: true,
            etaMedian: etaMedian,
            etaStdDev: etaStdDev,
            pFailure: 0,
            transferCount: transferCount,
            nextActionDeadline: nextActionDeadline,
            confidence: confidence,
            imminentVehicle: match.imminent,
            unavailableReason: nil
        )
    }

    // MARK: - Aggregate score

    /// Aggregate ranking score in seconds. Lower is better. Returns
    /// `.greatestFiniteMagnitude` for unavailable options so they
    /// always sort after available ones.
    public func score(
        _ evaluation: RouteEvaluation,
        now: Date,
        weights: ETAWeights? = nil
    ) -> Double {
        guard evaluation.available else { return .greatestFiniteMagnitude }
        let w = weights ?? self.weights
        let etaSeconds = evaluation.etaMedian.timeIntervalSince(now)
        return etaSeconds
            + w.lambdaVariance * evaluation.etaStdDev
            + w.lambdaFailure * evaluation.pFailure
            + w.lambdaTransfer * Double(evaluation.transferCount)
    }

    // MARK: - Helpers

    private func transitLegCount(_ option: RouteOption) -> Int {
        option.legs.reduce(0) { $0 + ($1.mode == .transit ? 1 : 0) }
    }

    private func totalEstimatedSeconds(_ option: RouteOption) -> TimeInterval {
        option.legs.reduce(0) { $0 + LegSpeed.estimatedSeconds(for: $1) }
    }

    private func estimatedSecondsAfter(
        firstTransitLeg target: RouteOptionLeg,
        in option: RouteOption
    ) -> TimeInterval {
        guard let firstIndex = option.legs.firstIndex(where: { $0.mode == .transit }) else {
            return 0
        }
        guard option.legs[firstIndex] == target else { return 0 }
        // `match.arrival.arrivalAt` is the boarding time, not the
        // alighting time — the snapshot has no per-stop progression
        // for the trip the user boards — so we approximate the
        // first-leg ride duration alongside the post-first-leg legs.
        // Subsequent transit legs go through this same estimator
        // until the evaluator can resolve their own arrivals.
        let firstLegRideSeconds = LegSpeed.estimatedSeconds(for: target)
        let tail = option.legs[(firstIndex + 1)...]
        let tailSeconds = tail.reduce(0) { $0 + LegSpeed.estimatedSeconds(for: $1) }
        return firstLegRideSeconds + tailSeconds
    }

    private func closedStationIDsTouched(
        option: RouteOption,
        closedIDs: Set<Int>
    ) -> Set<Int> {
        guard !closedIDs.isEmpty else { return [] }
        var hits: Set<Int> = []
        for leg in option.legs {
            for stop in [leg.fromStopID, leg.toStopID].compactMap({ $0 }) {
                if case .lStation(let id) = stop, closedIDs.contains(id) {
                    hits.insert(id)
                }
            }
        }
        return hits
    }

    /// Signed seconds — positive when API runs early (vehicle later
    /// than predicted, so ETA should grow), negative when API runs
    /// late.
    private func signedMedianSeconds(_ correction: ArrivalBiasCorrection) -> TimeInterval {
        switch correction.direction {
        case .apiEarly: return correction.magnitudeSeconds
        case .apiLate: return -correction.magnitudeSeconds
        }
    }
}
