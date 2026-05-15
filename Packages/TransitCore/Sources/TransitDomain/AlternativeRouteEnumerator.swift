import Foundation
import TransitModels

/// Pure helper that, given origin and destination anchors and the
/// user's habitual route, returns:
///
/// 1. A heuristic estimate of `usualTripSeconds` — the time the user
///    typically spends on their habitual route from origin to
///    destination.
/// 2. A set of candidate `AlternativeRoute` values (different L lines
///    or bus routes within walking distance of both anchors) with the
///    same heuristic applied for symmetric time comparison.
///
/// The heuristic is intentionally coarse — Haversine to find nearest
/// stops on each route, walking-speed ~80 m/min, in-vehicle speed
/// ~25 km/h for trains and ~18 km/h for buses, plus an average
/// headway-induced wait per mode. Real MapKit routing would be more
/// accurate but slower and rate-limited; what matters for the
/// pleasant-surprise pipeline is that *the same* heuristic is applied
/// to the usual route and to alternatives, so the relative time
/// penalties land in the right ballpark.
public struct AlternativeRouteEnumerator: Sendable {
    public struct EnumerationResult: Sendable, Hashable {
        public let usualTripSeconds: TimeInterval
        public let alternatives: [PleasantSurpriseSuggester.AlternativeRoute]

        public init(
            usualTripSeconds: TimeInterval,
            alternatives: [PleasantSurpriseSuggester.AlternativeRoute]
        ) {
            self.usualTripSeconds = usualTripSeconds
            self.alternatives = alternatives
        }
    }

    /// 80 m/min walking ≈ 4.8 km/h. Phase 5's walk-speed correction
    /// scales the relative time across routes but doesn't affect the
    /// ranking, so we use a flat default here.
    public static let defaultWalkingSpeedMetersPerSecond: Double = 80.0 / 60.0

    public init() {}

    public func enumerate(
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        usualPattern: MobilityProfileSummary.RoutePattern,
        lStationCatalog: [LStation] = LStationCatalog.all,
        busStopCatalog: [BusStop] = BusStopCatalog.all,
        searchRadiusMeters: Double = 800
    ) -> EnumerationResult? {
        // Usual trip baseline through the same heuristic.
        guard let usualTrip = estimateTripSeconds(
            mode: usualPattern.mode,
            routeId: usualPattern.routeId,
            origin: origin,
            destination: destination,
            lStationCatalog: lStationCatalog,
            busStopCatalog: busStopCatalog,
            searchRadiusMeters: searchRadiusMeters
        ) else { return nil }

        var alternatives: [PleasantSurpriseSuggester.AlternativeRoute] = []

        // Train alternatives. Each LineColor that's not the usual line.
        let usualIsTrain = (usualPattern.mode == .train)
        let trainLines: Set<LineColor> = Set(lStationCatalog.flatMap(\.servedLines))
        for line in trainLines {
            if usualIsTrain, line.rawValue == usualPattern.routeId { continue }
            guard let trip = estimateTripSeconds(
                mode: .train,
                routeId: line.rawValue,
                origin: origin,
                destination: destination,
                lStationCatalog: lStationCatalog,
                busStopCatalog: busStopCatalog,
                searchRadiusMeters: searchRadiusMeters
            ) else { continue }
            alternatives.append(PleasantSurpriseSuggester.AlternativeRoute(
                mode: .train,
                routeId: line.rawValue,
                displayName: "\(line.displayName) Line",
                projectedSeconds: trip
            ))
        }

        // Bus alternatives. Each unique route in the bus catalog.
        let usualIsBus = (usualPattern.mode == .bus)
        let busRoutes = Set(busStopCatalog.map(\.route))
        for route in busRoutes {
            if usualIsBus, route == usualPattern.routeId { continue }
            guard let trip = estimateTripSeconds(
                mode: .bus,
                routeId: route,
                origin: origin,
                destination: destination,
                lStationCatalog: lStationCatalog,
                busStopCatalog: busStopCatalog,
                searchRadiusMeters: searchRadiusMeters
            ) else { continue }
            alternatives.append(PleasantSurpriseSuggester.AlternativeRoute(
                mode: .bus,
                routeId: route,
                displayName: "Bus #\(route)",
                projectedSeconds: trip
            ))
        }

        return EnumerationResult(
            usualTripSeconds: usualTrip,
            alternatives: alternatives
        )
    }

    /// `nil` when no stop on `routeId` is within `searchRadiusMeters`
    /// of *both* origin and destination, or when origin and destination
    /// resolve to the same stop on this route (trivial trip).
    public func estimateTripSeconds(
        mode: MobilityProfileSummary.RoutePattern.Mode,
        routeId: String,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        lStationCatalog: [LStation] = LStationCatalog.all,
        busStopCatalog: [BusStop] = BusStopCatalog.all,
        searchRadiusMeters: Double = 800
    ) -> TimeInterval? {
        let originStop: (lat: Double, lon: Double)?
        let destStop: (lat: Double, lon: Double)?

        switch mode {
        case .train:
            guard let line = LineColor(rawValue: routeId) else { return nil }
            let stations = lStationCatalog.filter { $0.servedLines.contains(line) }
            originStop = nearest(stations.map { (lat: $0.latitude, lon: $0.longitude) }, to: origin)
            destStop = nearest(stations.map { (lat: $0.latitude, lon: $0.longitude) }, to: destination)
        case .bus:
            let stops = busStopCatalog.filter { $0.route == routeId }
            originStop = nearest(stops.map { (lat: $0.latitude, lon: $0.longitude) }, to: origin)
            destStop = nearest(stops.map { (lat: $0.latitude, lon: $0.longitude) }, to: destination)
        case .metra:
            // Metra catalog isn't in scope for the enumeration heuristic
            // yet — Metra's per-trip schedules are too distinct from
            // headway-based modes for the same wait estimate.
            return nil
        }

        guard let originStop, let destStop else { return nil }
        let walkOrigin = Distance.meters(from: origin, to: originStop)
        let walkDest = Distance.meters(from: destination, to: destStop)
        guard walkOrigin <= searchRadiusMeters, walkDest <= searchRadiusMeters else { return nil }

        let inVehicleMeters = Distance.meters(from: originStop, to: destStop)
        guard inVehicleMeters > 0 else { return nil }

        let speedMetersPerSecond: Double
        let avgWaitSeconds: TimeInterval
        switch mode {
        case .train:
            speedMetersPerSecond = 25_000.0 / 3600   // 25 km/h
            avgWaitSeconds = 5 * 60                  // 5-min CTA train headway
        case .bus:
            speedMetersPerSecond = 18_000.0 / 3600   // 18 km/h
            avgWaitSeconds = 8 * 60                  // 8-min CTA bus headway
        case .metra:
            return nil
        }

        let walkSeconds = (walkOrigin + walkDest) / Self.defaultWalkingSpeedMetersPerSecond
        let inVehicleSeconds = inVehicleMeters / speedMetersPerSecond
        return walkSeconds + avgWaitSeconds + inVehicleSeconds
    }

    /// Polyline (origin-stop, dest-stop) for a candidate route. Used
    /// by the off-commute geography index's `delightScore` to ask
    /// "does this route pass through cells the user has visited?"
    /// Two waypoints is coarse — but the cell index buckets at ~500 m,
    /// so a long L line spanning multiple neighborhoods would yield
    /// enough intermediate cells via the endpoints alone for an
    /// MVP-level signal.
    public func waypoints(
        mode: MobilityProfileSummary.RoutePattern.Mode,
        routeId: String,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        lStationCatalog: [LStation] = LStationCatalog.all,
        busStopCatalog: [BusStop] = BusStopCatalog.all
    ) -> [(lat: Double, lon: Double)] {
        switch mode {
        case .train:
            guard let line = LineColor(rawValue: routeId) else { return [] }
            let stations = lStationCatalog.filter { $0.servedLines.contains(line) }
                .map { (lat: $0.latitude, lon: $0.longitude) }
            guard let originStop = nearest(stations, to: origin),
                  let destStop = nearest(stations, to: destination) else { return [] }
            return [originStop, destStop]
        case .bus:
            let stops = busStopCatalog.filter { $0.route == routeId }
                .map { (lat: $0.latitude, lon: $0.longitude) }
            guard let originStop = nearest(stops, to: origin),
                  let destStop = nearest(stops, to: destination) else { return [] }
            return [originStop, destStop]
        case .metra:
            return []
        }
    }

    private func nearest(
        _ candidates: [(lat: Double, lon: Double)],
        to point: (lat: Double, lon: Double)
    ) -> (lat: Double, lon: Double)? {
        var best: (point: (lat: Double, lon: Double), distance: Double)?
        for candidate in candidates {
            let distance = Distance.meters(from: point, to: candidate)
            if let current = best {
                if distance < current.distance {
                    best = (candidate, distance)
                }
            } else {
                best = (candidate, distance)
            }
        }
        return best?.point
    }
}
