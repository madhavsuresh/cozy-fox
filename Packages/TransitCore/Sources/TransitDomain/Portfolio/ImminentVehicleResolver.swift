import Foundation
import TransitCache
import TransitModels

/// One concrete arrival matched to a `RouteOptionLeg`'s identity. Holds
/// the agency-specific value so callers can read `arrivalAt` and pull
/// the bias-correction key without re-searching the snapshot.
public enum ResolvedArrival: Sendable, Hashable {
    case train(Arrival)
    case bus(BusPrediction)
    case metra(MetraPrediction)
    case intercampus(IntercampusArrival)

    public var arrivalAt: Date {
        switch self {
        case .train(let a): a.arrivalAt
        case .bus(let p): p.arrivalAt
        case .metra(let p): p.arrivalAt
        case .intercampus(let a): a.arrivalAt
        }
    }

    /// Stable id from the underlying agency type, used for snapshot
    /// filtering (removing the matched arrival to compute miss cost).
    public var id: String {
        switch self {
        case .train(let a): a.id
        case .bus(let p): p.id
        case .metra(let p): p.id
        case .intercampus(let a): a.id
        }
    }

    public var imminent: ImminentVehicle {
        switch self {
        case .train(let a):
            return .train(runNumber: a.runNumber, stationID: a.stationId, line: a.line)
        case .bus(let p):
            return .bus(vehicleID: p.vehicleId, stopID: p.stopId, route: p.route)
        case .metra(let p):
            return .metra(tripID: p.tripId, stationID: p.stationId, route: p.routeId)
        case .intercampus(let a):
            return .intercampus(tripID: a.tripId, stopID: a.stopId, direction: a.direction)
        }
    }

    /// `BiasArrivalRef` for looking up this arrival's historical bias
    /// correction. `nil` for modes not currently graded by
    /// `ArrivalGrader` — Metra and intercampus.
    public var biasRef: BiasArrivalRef? {
        switch self {
        case .train(let a):
            return .train(line: a.line, stopID: a.stopId, directionCode: a.directionCode)
        case .bus(let p):
            return .bus(route: p.route, stopID: p.stopId, directionName: p.directionName)
        case .metra, .intercampus:
            return nil
        }
    }
}

public struct ImminentVehicleMatch: Sendable, Hashable {
    public let imminent: ImminentVehicle
    public let arrival: ResolvedArrival
    /// Walk time from the user's current location to the matched
    /// arrival's board stop, in seconds. `0` when no user location is
    /// known or no walking-cache entry exists — the match was selected
    /// without a catchability check in that case.
    public let walkSecondsToStop: TimeInterval
    /// `arrival.arrivalAt - now - walkSecondsToStop`. Non-negative for
    /// every match the resolver returns (uncatchable arrivals are
    /// filtered out unless walk time was unknown, in which case the
    /// margin is just `arrivalAt - now`).
    public let catchMarginSeconds: TimeInterval

    public init(
        imminent: ImminentVehicle,
        arrival: ResolvedArrival,
        walkSecondsToStop: TimeInterval,
        catchMarginSeconds: TimeInterval
    ) {
        self.imminent = imminent
        self.arrival = arrival
        self.walkSecondsToStop = walkSecondsToStop
        self.catchMarginSeconds = catchMarginSeconds
    }
}

/// Picks "the vehicle to catch" for a `RouteOption`'s first transit
/// leg. Filters the snapshot's arrivals by the leg's identity
/// (line+stop / route+stop), drops anything outside the look-ahead
/// horizon or that the user can't physically reach in time, then
/// returns the earliest remaining arrival.
///
/// Pure / `Sendable`. Walk time is consulted via `PortfolioSnapshot
/// .walkingDistance`; when the cache hasn't populated for this origin
/// × stop pair the resolver assumes zero walk time so cold launches
/// still surface arrivals (the scorer marks confidence low when this
/// happens).
public struct ImminentVehicleResolver: Sendable {
    /// Extra slack between "the user arrives at the platform" and "the
    /// vehicle's reported arrival". A small positive buffer avoids
    /// surfacing arrivals that are technically catchable but require a
    /// sprint.
    public let walkBufferSeconds: TimeInterval
    /// Look-ahead horizon. Past this point, the resolver returns nil
    /// and the option is marked `.noArrivalsInHorizon`.
    public let horizon: TimeInterval

    public init(walkBufferSeconds: TimeInterval = 60, horizon: TimeInterval = 45 * 60) {
        self.walkBufferSeconds = walkBufferSeconds
        self.horizon = horizon
    }

    public func resolve(
        firstTransitLeg leg: RouteOptionLeg,
        snapshot: PortfolioSnapshot
    ) -> ImminentVehicleMatch? {
        guard leg.mode == .transit else { return nil }
        guard let resolution = leg.transit?.resolution else { return nil }
        guard let fromStop = leg.fromStopID else { return nil }

        let now = snapshot.now
        let horizonEnd = now.addingTimeInterval(horizon)

        let candidates = matchingArrivals(
            resolution: resolution,
            fromStop: fromStop,
            in: snapshot.snapshot
        )
        .filter { $0.arrivalAt > now && $0.arrivalAt <= horizonEnd }
        .sorted { $0.arrivalAt < $1.arrivalAt }

        guard !candidates.isEmpty else { return nil }

        let walkSeconds = walkSecondsToStop(fromStop, snapshot: snapshot)

        // Catchability filter. When walk time is unknown we don't
        // filter (`walkSeconds == nil`) — the scorer marks this as low
        // confidence.
        let pickList: [ResolvedArrival]
        if let walk = walkSeconds {
            pickList = candidates.filter { arrival in
                arrival.arrivalAt.timeIntervalSince(now) >= walk + walkBufferSeconds
            }
        } else {
            pickList = candidates
        }

        guard let pick = pickList.first else { return nil }

        let resolvedWalk = walkSeconds ?? 0
        let margin = pick.arrivalAt.timeIntervalSince(now) - resolvedWalk
        return ImminentVehicleMatch(
            imminent: pick.imminent,
            arrival: pick,
            walkSecondsToStop: resolvedWalk,
            catchMarginSeconds: margin
        )
    }

    // MARK: - Identity matching

    private func matchingArrivals(
        resolution: TransitResolution,
        fromStop: TransitStopRef,
        in snapshot: TransitSnapshot
    ) -> [ResolvedArrival] {
        switch (resolution, fromStop) {
        case (.line(let line), .lStation(let stationID)):
            return snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == stationID }
                .map(ResolvedArrival.train)
        case (.line(let line), .lPlatform(let stopID)):
            return snapshot.trainArrivals
                .filter { $0.line == line && $0.stopId == stopID }
                .map(ResolvedArrival.train)
        case (.bus(let route), .bus(let stopID)):
            return snapshot.busPredictions
                .filter { $0.route == route && $0.stopId == stopID }
                .map(ResolvedArrival.bus)
        case (.metra(let route), .metra(let stationID)):
            return snapshot.metraPredictions
                .filter { $0.routeId == route && $0.stationId == stationID }
                .map(ResolvedArrival.metra)
        case (.unknown, _), (_, .intercampus):
            // Intercampus legs aren't routed through `TransitResolution`
            // — there's no `.intercampus` case on `TransitResolution`
            // and no `.intercampus` case on `TransitStopRef` paired
            // with a matching resolution. v0 leaves this unhandled.
            return []
        default:
            // Mismatched pairings (e.g. `.line` paired with `.bus(...)`)
            // — these are construction errors in the portfolio and
            // would never resolve.
            return []
        }
    }

    private func walkSecondsToStop(
        _ stop: TransitStopRef,
        snapshot: PortfolioSnapshot
    ) -> TimeInterval? {
        guard let user = snapshot.userLocation else { return nil }
        return snapshot.walkingDistance.walkSeconds(
            from: (lat: user.latitude, lon: user.longitude),
            to: stop
        )
    }
}

public extension RouteOption {
    /// The first leg with `mode == .transit`, or nil for walking-only
    /// options. Used by the resolver to pick the vehicle to catch and
    /// by the scorer to compute ETA branches.
    var firstTransitLeg: RouteOptionLeg? {
        legs.first(where: { $0.mode == .transit })
    }
}
