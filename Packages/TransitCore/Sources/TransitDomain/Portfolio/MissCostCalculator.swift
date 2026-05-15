import Foundation
import TransitCache
import TransitModels

/// "If the user misses this recommendation, what happens?" Encodes the
/// next-best ETA and whether it's a same-route fallback (next vehicle on
/// the same line at the same stop) or a cross-route fallback (a
/// different option in the portfolio). `collapses == true` means there
/// is no fallback within horizon — typically the last train of the
/// night.
public struct MissCostResult: Sendable, Hashable {
    /// Seconds between catching the recommendation vs. missing it.
    /// Always non-negative; zero when same-route bunched arrivals
    /// arrive at the same time.
    public let delta: TimeInterval
    /// `[0, 1]`. How comfortable the recommended catch is — `1` means
    /// the user has plenty of margin to walk to the stop, `0` means
    /// they'd need to sprint and may not make it. Linear from 60s
    /// margin (0) to 5 min (1).
    public let catchability: Double
    public let etaIfCaught: Date
    public let etaIfMissed: Date
    /// The `RouteOption.id` that takes over when the user misses. May
    /// be the same option (same-route next vehicle) or a different
    /// one in the portfolio (cross-route fallback).
    public let fallbackOptionID: UUID
    /// `true` when no fallback exists within `resolver.horizon`. This
    /// includes the explicit last-train-of-night case detected by
    /// `LastTrainSafety` and the more generic "no other route helps"
    /// case.
    public let collapses: Bool

    public init(
        delta: TimeInterval,
        catchability: Double,
        etaIfCaught: Date,
        etaIfMissed: Date,
        fallbackOptionID: UUID,
        collapses: Bool
    ) {
        self.delta = delta
        self.catchability = catchability
        self.etaIfCaught = etaIfCaught
        self.etaIfMissed = etaIfMissed
        self.fallbackOptionID = fallbackOptionID
        self.collapses = collapses
    }
}

/// Computes the miss cost for a portfolio's recommended option against
/// a `PortfolioSnapshot`. Pure / `Sendable`.
///
/// Algorithm:
/// 1. If the recommendation is walking-only (no imminent vehicle),
///    return nil — there's nothing to miss.
/// 2. Build a filtered snapshot with the imminent arrival removed.
/// 3. Re-evaluate the recommended option under the filtered snapshot
///    — that's the **same-route fallback** (next vehicle on the same
///    line at the same stop).
/// 4. Re-evaluate every other option in the portfolio under the
///    filtered snapshot — those are the **cross-route fallbacks**.
/// 5. Take the available fallback with the earliest ETA.
/// 6. If no fallback is available, check `LastTrainSafety.warning(...)`
///    against the recommended option's terminal transit leg arrivals.
///    Either way, `collapses = true`; the warning case is the
///    "service-ending" variant the dashboard should call out.
public struct MissCostCalculator: Sendable {
    public let scorer: RouteOptionScorer
    public let lastTrainDetector: LastTrainSafety

    public init(
        scorer: RouteOptionScorer = RouteOptionScorer(),
        lastTrainDetector: LastTrainSafety = LastTrainSafety()
    ) {
        self.scorer = scorer
        self.lastTrainDetector = lastTrainDetector
    }

    public func missCost(
        recommended: RouteEvaluation,
        portfolio: RoutePortfolio,
        snapshot: PortfolioSnapshot
    ) -> MissCostResult? {
        // Walking-only — no vehicle to miss.
        guard let imminent = recommended.imminentVehicle else { return nil }
        guard recommended.available else { return nil }

        // Locate the recommended option in the portfolio for re-evaluation.
        guard let recommendedOption = portfolio.options.first(where: { $0.id == recommended.optionID }) else {
            return nil
        }

        // Construct the filtered snapshot: drop the matched arrival from
        // the underlying TransitSnapshot. Need to find the arrival id
        // by re-running the resolver — its match contains both the
        // ImminentVehicle (for hashing) and the ResolvedArrival (for id).
        guard let firstLeg = recommendedOption.firstTransitLeg,
              let match = scorer.resolver.resolve(firstTransitLeg: firstLeg, snapshot: snapshot)
        else {
            return nil
        }
        // Sanity check: the re-resolved match must be the same vehicle
        // as the recommendation. If the snapshot has shifted between
        // the recommendation being made and miss-cost being computed,
        // bail rather than silently scoring against a different vehicle.
        guard match.imminent == imminent else { return nil }

        let filtered = filteredSnapshot(snapshot, removing: match.arrival)

        // Same-route fallback: re-evaluate the recommended option.
        let sameRouteEval = scorer.evaluate(option: recommendedOption, snapshot: filtered)

        // Cross-route fallbacks: every other option in the portfolio.
        let crossRouteEvals = portfolio.options
            .filter { $0.id != recommended.optionID }
            .map { scorer.evaluate(option: $0, snapshot: filtered) }

        let allFallbacks = ([sameRouteEval] + crossRouteEvals).filter(\.available)

        guard let best = allFallbacks.min(by: { $0.etaMedian < $1.etaMedian }) else {
            // No fallback in horizon. Check if `LastTrainSafety`
            // confirms this is service-ending; either way it's a
            // collapse.
            return MissCostResult(
                delta: .infinity,
                catchability: catchability(of: match),
                etaIfCaught: recommended.etaMedian,
                etaIfMissed: .distantFuture,
                fallbackOptionID: recommended.optionID,
                collapses: true
            )
        }

        let delta = max(0, best.etaMedian.timeIntervalSince(recommended.etaMedian))
        // Last-train detection: gate independently of fallback
        // availability so we can flag late-night collapse even when
        // bunched same-route arrivals exist. (A bunched 23:55 + 23:58
        // pair still ends service.)
        let isLastTrain = lastTrainCollapses(
            recommendedOption: recommendedOption,
            match: match,
            snapshot: snapshot
        )

        return MissCostResult(
            delta: delta,
            catchability: catchability(of: match),
            etaIfCaught: recommended.etaMedian,
            etaIfMissed: best.etaMedian,
            fallbackOptionID: best.optionID,
            collapses: isLastTrain
        )
    }

    // MARK: - Helpers

    /// Snapshot-without-the-imminent-arrival. The new snapshot reuses
    /// the same readers and metadata; only the arrival list for the
    /// matched arrival's mode is filtered.
    private func filteredSnapshot(
        _ snapshot: PortfolioSnapshot,
        removing arrival: ResolvedArrival
    ) -> PortfolioSnapshot {
        var inner = snapshot.snapshot
        let removeID = arrival.id
        switch arrival {
        case .train:
            inner.trainArrivals = inner.trainArrivals.filter { $0.id != removeID }
        case .bus:
            inner.busPredictions = inner.busPredictions.filter { $0.id != removeID }
        case .metra:
            inner.metraPredictions = inner.metraPredictions.filter { $0.id != removeID }
        case .intercampus:
            inner.intercampusArrivals = inner.intercampusArrivals.filter { $0.id != removeID }
        }
        return PortfolioSnapshot(
            snapshot: inner,
            now: snapshot.now,
            userLocation: snapshot.userLocation,
            walkingDistance: snapshot.walkingDistance,
            biasCorrection: snapshot.biasCorrection,
            closedStationIDs: snapshot.closedStationIDs
        )
    }

    /// Linear mapping from catch margin to comfort. Below 60s margin
    /// the user has effectively no slack; at 5 min they have plenty.
    /// Values clip to `[0, 1]`.
    private func catchability(of match: ImminentVehicleMatch) -> Double {
        let floor: TimeInterval = 60
        let ceiling: TimeInterval = 5 * 60
        let raw = (match.catchMarginSeconds - floor) / (ceiling - floor)
        return max(0, min(1, raw))
    }

    /// `LastTrainSafety` fires on the recommended option's first
    /// transit leg arrivals — same identity matching the resolver
    /// uses, just unfiltered by catchability so the detector sees the
    /// full upcoming-arrivals shape.
    private func lastTrainCollapses(
        recommendedOption: RouteOption,
        match: ImminentVehicleMatch,
        snapshot: PortfolioSnapshot
    ) -> Bool {
        guard case .train(let arrival) = match.arrival else { return false }
        let upcoming = snapshot.snapshot.trainArrivals.filter {
            $0.line == arrival.line && $0.stationId == arrival.stationId
        }
        return lastTrainDetector.warning(forArrivals: upcoming, now: snapshot.now) != nil
    }
}
