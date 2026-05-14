import Foundation
import TransitModels

/// Builds comparison trip plans from origin → destination using only the
/// bundled CTA and Metra catalogs. Used as a fallback when
/// `MKDirections.calculate(.transit)` returns "operation couldn't be
/// completed" — which is the documented behavior of Apple's transit-routing
/// API ("Only supported for ETA calculations") in many regions/builds.
///
/// Heuristic, not a real router:
/// - Score every L line, Metra route, and bus route by
///   `originWalk + transit + destWalk` minutes, using ballpark speeds.
/// - Also score transfer routes, so options like "65 to Grand, then Blue
///   Line" or "bus north to Belmont, then 77 west" can appear when a direct
///   walk/bike to the second leg is not the only reasonable way to start the
///   trip.
/// - Require the transit option to beat a direct walk by at least 15 %.
/// - Use straight-line distances; real route polylines are unavailable here.
public struct LocalTransitPlanner: Sendable {
    private static let transferBucketSize = 0.01
    private static let maxOriginTransferRoutes = 12
    private static let maxDestinationTransferRoutes = 12
    private static let maxOneTransferCandidates = 32
    private static let maxOneTransferEdgesPerRoutePair = 3
    private static let maxThreeLegTransferCandidates = 4
    private static let maxThreeLegCombinations = 512
    private static let maxNearbyTransferEdgesPerRoute = 18
    private static let maxNearbyTransferEdgesPerRoutePair = 1

    public let walkingMetersPerMinute: Double
    public let lTrainMetersPerMinute: Double
    public let busMetersPerMinute: Double
    public let metraMetersPerMinute: Double
    public let lTrainBoardingWaitMinutes: Double
    public let busBoardingWaitMinutes: Double
    public let metraBoardingWaitMinutes: Double
    public let minimumTripSavingsFactor: Double
    public let maxStationWalkMeters: Double
    public let maxStopWalkMeters: Double
    public let maxTransferWalkMeters: Double
    public let maxMetraStationWalkMeters: Double
    public let minDirectWalkMeters: Double
    public let minBusTransitMeters: Double
    public let minTrainTransitMeters: Double
    public let maxTrainPlans: Int
    public let maxBusPlans: Int
    public let maxBusToTrainPlans: Int
    public let maxTransferTransitLegs: Int
    public let maxMetraPlans: Int

    public init(
        walkingMetersPerMinute: Double = 84,
        lTrainMetersPerMinute: Double = 670,
        busMetersPerMinute: Double = 270,
        metraMetersPerMinute: Double = 900,
        lTrainBoardingWaitMinutes: Double = 3,
        busBoardingWaitMinutes: Double = 5,
        metraBoardingWaitMinutes: Double = 8,
        minimumTripSavingsFactor: Double = 0.85,
        maxStationWalkMeters: Double = 1_500,
        maxStopWalkMeters: Double = 750,
        maxTransferWalkMeters: Double = 600,
        maxMetraStationWalkMeters: Double = 3_000,
        minDirectWalkMeters: Double = 800,
        minBusTransitMeters: Double = 500,
        minTrainTransitMeters: Double = 800,
        maxTrainPlans: Int = 12,
        maxBusPlans: Int = 16,
        maxBusToTrainPlans: Int = 16,
        maxTransferTransitLegs: Int = 3,
        maxMetraPlans: Int = 8
    ) {
        self.walkingMetersPerMinute = walkingMetersPerMinute
        self.lTrainMetersPerMinute = lTrainMetersPerMinute
        self.busMetersPerMinute = busMetersPerMinute
        self.metraMetersPerMinute = metraMetersPerMinute
        self.lTrainBoardingWaitMinutes = lTrainBoardingWaitMinutes
        self.busBoardingWaitMinutes = busBoardingWaitMinutes
        self.metraBoardingWaitMinutes = metraBoardingWaitMinutes
        self.minimumTripSavingsFactor = minimumTripSavingsFactor
        self.maxStationWalkMeters = maxStationWalkMeters
        self.maxStopWalkMeters = maxStopWalkMeters
        self.maxTransferWalkMeters = maxTransferWalkMeters
        self.maxMetraStationWalkMeters = maxMetraStationWalkMeters
        self.minDirectWalkMeters = minDirectWalkMeters
        self.minBusTransitMeters = minBusTransitMeters
        self.minTrainTransitMeters = minTrainTransitMeters
        self.maxTrainPlans = maxTrainPlans
        self.maxBusPlans = maxBusPlans
        self.maxBusToTrainPlans = maxBusToTrainPlans
        self.maxTransferTransitLegs = maxTransferTransitLegs
        self.maxMetraPlans = maxMetraPlans
    }

    public func plan(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate,
        profile: MobilityProfile = .empty,
        now: Date = .now,
        calendar: Calendar = .current,
        stations: [LStation] = LStationCatalog.all,
        busStops: [BusStop] = BusStopCatalog.all,
        metraStations: [MetraStation] = MetraStationCatalog.all
    ) -> [TripPlan] {
        let ranker = TripHistoryRanker(
            profile: profile,
            origin: origin,
            destination: destination,
            now: now,
            calendar: calendar
        )
        let originPair: (lat: Double, lon: Double) = (origin.latitude, origin.longitude)
        let destinationPair: (lat: Double, lon: Double) = (destination.latitude, destination.longitude)
        let directMeters = Distance.meters(from: originPair, to: destinationPair)
        guard directMeters >= minDirectWalkMeters else { return [] }
        let directWalkMinutes = directMeters / walkingMetersPerMinute

        var trainCandidates: [Candidate] = []
        var trainKeys: Set<String> = []
        for line in LineColor.allCases {
            let onLine = stations.filter { $0.servedLines.contains(line) }
            let candidateLimit = max(2, maxTrainPlans)
            let originStations = nearest(
                in: onLine,
                to: originPair,
                maxMeters: maxStationWalkMeters,
                limit: candidateLimit
            )
            let destinationStations = nearest(
                in: onLine,
                to: destinationPair,
                maxMeters: maxStationWalkMeters,
                limit: candidateLimit
            )

            for originStation in originStations {
                for destStation in destinationStations where originStation.entry.id != destStation.entry.id {
                    let transitMeters = Distance.meters(
                        from: (originStation.entry.latitude, originStation.entry.longitude),
                        to: (destStation.entry.latitude, destStation.entry.longitude)
                    )
                    guard transitMeters >= minTrainTransitMeters else { continue }

                    let totalMinutes =
                        originStation.distance / walkingMetersPerMinute
                        + transitMeters / lTrainMetersPerMinute
                        + destStation.distance / walkingMetersPerMinute
                        + lTrainBoardingWaitMinutes

                    guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                    let candidate = Candidate(
                        resolution: .line(line),
                        displayName: line.displayName,
                        originStopName: originStation.entry.name,
                        destinationStopName: destStation.entry.name,
                        originStopCoordinate: PlannerCoordinate(
                            latitude: originStation.entry.latitude,
                            longitude: originStation.entry.longitude
                        ),
                        destinationStopCoordinate: PlannerCoordinate(
                            latitude: destStation.entry.latitude,
                            longitude: destStation.entry.longitude
                        ),
                        originWalkMeters: originStation.distance,
                        transitMeters: transitMeters,
                        destinationWalkMeters: destStation.distance,
                        totalMinutes: totalMinutes
                    )
                    appendUniqueCandidate(candidate, to: &trainCandidates, seen: &trainKeys)
                }
            }
        }

        var metraCandidates: [Candidate] = []
        var metraKeys: Set<String> = []
        for line in MetraStationCatalog.routes {
            let onLine = metraStations.filter { $0.servedRoutes.contains(line.id) }
            let candidateLimit = max(2, maxMetraPlans)
            let originStations = nearest(
                in: onLine,
                to: originPair,
                maxMeters: maxMetraStationWalkMeters,
                limit: candidateLimit
            )
            let destinationStations = nearest(
                in: onLine,
                to: destinationPair,
                maxMeters: maxMetraStationWalkMeters,
                limit: candidateLimit
            )

            for originStation in originStations {
                for destStation in destinationStations where originStation.entry.id != destStation.entry.id {
                    let transitMeters = Distance.meters(
                        from: (originStation.entry.latitude, originStation.entry.longitude),
                        to: (destStation.entry.latitude, destStation.entry.longitude)
                    )
                    let totalMinutes =
                        originStation.distance / walkingMetersPerMinute
                        + transitMeters / metraMetersPerMinute
                        + destStation.distance / walkingMetersPerMinute
                        + metraBoardingWaitMinutes

                    guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                    let candidate = Candidate(
                        resolution: .metra(line.id),
                        displayName: "Metra \(line.shortName)",
                        originStopName: originStation.entry.name,
                        destinationStopName: destStation.entry.name,
                        originStopCoordinate: PlannerCoordinate(
                            latitude: originStation.entry.latitude,
                            longitude: originStation.entry.longitude
                        ),
                        destinationStopCoordinate: PlannerCoordinate(
                            latitude: destStation.entry.latitude,
                            longitude: destStation.entry.longitude
                        ),
                        originWalkMeters: originStation.distance,
                        transitMeters: transitMeters,
                        destinationWalkMeters: destStation.distance,
                        totalMinutes: totalMinutes
                    )
                    appendUniqueCandidate(candidate, to: &metraCandidates, seen: &metraKeys)
                }
            }
        }

        // Bus side: collect every viable route, then label the two classic
        // tradeoffs while keeping additional distinct routes as alternatives.
        let byRoute = Dictionary(grouping: busStops, by: \.route)
        let uniqueStopsByRoute = byRoute.mapValues { stops in
            var seen: Set<Int> = []
            return stops.filter { seen.insert($0.id).inserted }
        }
        let originStopByRoute: [String: (entry: BusStop, distance: Double)] = uniqueStopsByRoute.compactMapValues {
            closest(in: $0, to: originPair, maxMeters: maxStopWalkMeters)
        }
        let destinationStopByRoute: [String: (entry: BusStop, distance: Double)] = uniqueStopsByRoute.compactMapValues {
            closest(in: $0, to: destinationPair, maxMeters: maxStopWalkMeters)
        }

        var busCandidates: [Candidate] = []
        var busKeys: Set<String> = []
        for route in uniqueStopsByRoute.keys {
            guard
                let originStop = originStopByRoute[route],
                let destStop = destinationStopByRoute[route],
                originStop.entry.id != destStop.entry.id
            else { continue }

            let transitMeters = Distance.meters(
                from: (originStop.entry.latitude, originStop.entry.longitude),
                to: (destStop.entry.latitude, destStop.entry.longitude)
            )
            guard transitMeters >= minBusTransitMeters else { continue }

            let totalMinutes =
                originStop.distance / walkingMetersPerMinute
                + transitMeters / busMetersPerMinute
                + destStop.distance / walkingMetersPerMinute
                + busBoardingWaitMinutes

            guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

            let candidate = Candidate(
                resolution: .bus(route),
                displayName: "Route \(route)",
                originStopName: originStop.entry.name,
                destinationStopName: destStop.entry.name,
                originStopCoordinate: PlannerCoordinate(
                    latitude: originStop.entry.latitude,
                    longitude: originStop.entry.longitude
                ),
                destinationStopCoordinate: PlannerCoordinate(
                    latitude: destStop.entry.latitude,
                    longitude: destStop.entry.longitude
                ),
                originWalkMeters: originStop.distance,
                transitMeters: transitMeters,
                destinationWalkMeters: destStop.distance,
                totalMinutes: totalMinutes
            )
            appendUniqueCandidate(candidate, to: &busCandidates, seen: &busKeys)
        }

        let shortestRide = busCandidates.min { $0.transitMeters < $1.transitMeters }
        let shortestWalk = busCandidates.min {
            ($0.originWalkMeters + $0.destinationWalkMeters)
                < ($1.originWalkMeters + $1.destinationWalkMeters)
        }

        var selectedBusCandidates: [(candidate: Candidate, flavor: TripPlanFlavor)] = []
        var selectedBusKeys: Set<String> = []
        func appendBusCandidate(_ candidate: Candidate, flavor: TripPlanFlavor) {
            guard maxBusPlans > 0 else { return }
            guard selectedBusCandidates.count < maxBusPlans else { return }
            let key = candidateKey(candidate)
            guard selectedBusKeys.insert(key).inserted else { return }
            selectedBusCandidates.append((candidate, flavor))
        }

        let shortestRideKey = shortestRide.map(candidateKey)
        let shortestWalkKey = shortestWalk.map(candidateKey)
        func flavor(for candidate: Candidate) -> TripPlanFlavor {
            let key = candidateKey(candidate)
            if key == shortestWalkKey, key != shortestRideKey {
                return .busShortestWalk
            }
            return .busShortestRide
        }

        for candidate in busCandidates.sorted(by: { lhs, rhs in
            historyFirst(lhs, rhs, ranker: ranker)
        }) where ranker.score(resolution: candidate.resolution) > 0 {
            appendBusCandidate(candidate, flavor: flavor(for: candidate))
        }
        if let shortestRide {
            appendBusCandidate(shortestRide, flavor: .busShortestRide)
        }
        if let shortestWalk, shortestWalkKey != shortestRideKey {
            appendBusCandidate(shortestWalk, flavor: .busShortestWalk)
        }
        for candidate in busCandidates.sorted(by: { $0.totalMinutes < $1.totalMinutes }) {
            appendBusCandidate(candidate, flavor: .busShortestRide)
        }

        let transferCandidates = multiLegTransferCandidates(
            origin: originPair,
            destination: destinationPair,
            directWalkMinutes: directWalkMinutes,
            stations: stations,
            uniqueStopsByRoute: uniqueStopsByRoute,
            originStopByRoute: originStopByRoute,
            destinationStopByRoute: destinationStopByRoute
        )

        var plans: [TripPlan] = []
        for candidate in trainCandidates.sorted(by: { lhs, rhs in
            historyFirst(lhs, rhs, ranker: ranker)
        }).prefix(max(0, maxTrainPlans)) {
            plans.append(makePlan(from: candidate, flavor: .train))
        }
        for candidate in transferCandidates.sorted(by: { lhs, rhs in
            historyFirst(lhs, rhs, ranker: ranker)
        }).prefix(max(0, maxBusToTrainPlans)) {
            plans.append(makePlan(from: candidate))
        }
        for candidate in metraCandidates.sorted(by: { lhs, rhs in
            historyFirst(lhs, rhs, ranker: ranker)
        }).prefix(max(0, maxMetraPlans)) {
            plans.append(makePlan(from: candidate, flavor: .metra))
        }
        for entry in selectedBusCandidates {
            plans.append(makePlan(from: entry.candidate, flavor: entry.flavor))
        }
        return ranker.rankPlans(plans)
    }

    private func multiLegTransferCandidates(
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        directWalkMinutes: Double,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]],
        originStopByRoute: [String: (entry: BusStop, distance: Double)],
        destinationStopByRoute: [String: (entry: BusStop, distance: Double)]
    ) -> [TransferPathCandidate] {
        guard maxTransferTransitLegs >= 2, maxBusToTrainPlans > 0 else { return [] }

        var originBoardings: [LocalTransitRoute: PointDistance] = [:]
        var destinationAlightings: [LocalTransitRoute: PointDistance] = [:]

        for (route, stop) in originStopByRoute {
            originBoardings[.bus(route)] = PointDistance(point: transitPoint(stop.entry), distance: stop.distance)
        }
        for (route, stop) in destinationStopByRoute {
            destinationAlightings[.bus(route)] = PointDistance(point: transitPoint(stop.entry), distance: stop.distance)
        }
        for line in LineColor.allCases {
            guard let profile = routeProfile(
                for: .train(line),
                stations: stations,
                uniqueStopsByRoute: uniqueStopsByRoute
            ) else { continue }
            if let point = closestPoint(in: profile, to: origin, maxMeters: maxStationWalkMeters) {
                originBoardings[profile.route] = point
            }
            if let point = closestPoint(in: profile, to: destination, maxMeters: maxStationWalkMeters) {
                destinationAlightings[profile.route] = point
            }
        }
        guard !originBoardings.isEmpty, !destinationAlightings.isEmpty else { return [] }

        let originRoutes = cappedTransferEndpoints(originBoardings, limit: Self.maxOriginTransferRoutes)
        let destinationRoutes = cappedTransferEndpoints(destinationAlightings, limit: Self.maxDestinationTransferRoutes)
        let endpointRoutes = Set(originRoutes.map(\.route)).union(destinationRoutes.map(\.route))
        let endpointProfiles = routeProfiles(
            for: endpointRoutes,
            stations: stations,
            uniqueStopsByRoute: uniqueStopsByRoute
        )

        var candidateByKey: [String: TransferPathCandidate] = [:]
        let oneTransferCandidates = oneTransferCandidates(
            originRoutes: originRoutes,
            destinationRoutes: destinationRoutes,
            profilesByRoute: endpointProfiles,
            directWalkMinutes: directWalkMinutes,
            limit: min(maxBusToTrainPlans, Self.maxOneTransferCandidates)
        )
        for candidate in oneTransferCandidates {
            candidateByKey[transferPathKey(candidate)] = candidate
        }

        if maxTransferTransitLegs >= 3, candidateByKey.count < maxBusToTrainPlans {
            let remainingBudget = min(
                maxBusToTrainPlans - candidateByKey.count,
                Self.maxThreeLegTransferCandidates
            )
            let threeLegCandidates = threeLegTransferCandidates(
                originRoutes: originRoutes,
                destinationRoutes: destinationRoutes,
                stations: stations,
                uniqueStopsByRoute: uniqueStopsByRoute,
                directWalkMinutes: directWalkMinutes,
                limit: remainingBudget
            )
            for candidate in threeLegCandidates {
                let key = transferPathKey(candidate)
                if candidateByKey[key].map({ candidate.totalMinutes < $0.totalMinutes }) ?? true {
                    candidateByKey[key] = candidate
                }
            }
        }

        return candidateByKey.values.sorted(by: transferCandidateSort)
    }

    private func cappedTransferEndpoints(
        _ endpoints: [LocalTransitRoute: PointDistance],
        limit: Int
    ) -> [TransferEndpoint] {
        endpoints
            .map { TransferEndpoint(route: $0.key, pointDistance: $0.value) }
            .sorted { lhs, rhs in
                if abs(lhs.pointDistance.distance - rhs.pointDistance.distance) > 0.1 {
                    return lhs.pointDistance.distance < rhs.pointDistance.distance
                }
                return routeKey(lhs.route) < routeKey(rhs.route)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private func routeProfile(
        for route: LocalTransitRoute,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]]
    ) -> RouteProfile? {
        let points: [TransitPoint]
        switch route {
        case .bus(let route):
            points = uniqueStopsByRoute[route, default: []].map(transitPoint)
        case .train(let line):
            points = stations
                .filter { $0.servedLines.contains(line) }
                .map(transitPoint)
        }
        guard !points.isEmpty else { return nil }
        return RouteProfile(route: route, points: points)
    }

    private func routeProfiles(
        for routes: Set<LocalTransitRoute>,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]]
    ) -> [LocalTransitRoute: RouteProfile] {
        Dictionary(uniqueKeysWithValues: routes.compactMap { route in
            routeProfile(
                for: route,
                stations: stations,
                uniqueStopsByRoute: uniqueStopsByRoute
            ).map { (route, $0) }
        })
    }

    private func routeProfiles(
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]]
    ) -> [RouteProfile] {
        let trainProfiles = LineColor.allCases.compactMap { line -> RouteProfile? in
            let points = stations
                .filter { $0.servedLines.contains(line) }
                .map(transitPoint)
            guard !points.isEmpty else { return nil }
            return RouteProfile(route: .train(line), points: points)
        }
        let busProfiles = uniqueStopsByRoute
            .map { route, stops in
                RouteProfile(route: .bus(route), points: stops.map(transitPoint))
            }
            .filter { !$0.points.isEmpty }
        return trainProfiles + busProfiles
    }

    private func oneTransferCandidates(
        originRoutes: [TransferEndpoint],
        destinationRoutes: [TransferEndpoint],
        profilesByRoute: [LocalTransitRoute: RouteProfile],
        directWalkMinutes: Double,
        limit: Int
    ) -> [TransferPathCandidate] {
        guard limit > 0 else { return [] }

        var candidateByKey: [String: TransferPathCandidate] = [:]
        for originEndpoint in originRoutes {
            guard let originProfile = profilesByRoute[originEndpoint.route] else { continue }
            for destinationEndpoint in destinationRoutes where originEndpoint.route != destinationEndpoint.route {
                guard let destinationProfile = profilesByRoute[destinationEndpoint.route] else { continue }
                for edge in transferEdges(
                    from: originProfile,
                    to: destinationProfile,
                    limit: Self.maxOneTransferEdgesPerRoutePair
                ) {
                    guard
                        let firstSegment = transferSegment(
                            route: originEndpoint.route,
                            from: originEndpoint.pointDistance.point,
                            to: edge.fromPoint
                        ),
                        let secondSegment = transferSegment(
                            route: destinationEndpoint.route,
                            from: edge.toPoint,
                            to: destinationEndpoint.pointDistance.point
                        )
                    else { continue }

                    let totalMinutes = originEndpoint.pointDistance.distance / walkingMetersPerMinute
                        + rideMinutes(for: firstSegment)
                        + boardingWaitMinutes(for: firstSegment.route)
                        + edge.distance / walkingMetersPerMinute
                        + rideMinutes(for: secondSegment)
                        + boardingWaitMinutes(for: secondSegment.route)
                        + destinationEndpoint.pointDistance.distance / walkingMetersPerMinute
                    guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                    let candidate = TransferPathCandidate(
                        segments: [firstSegment, secondSegment],
                        originWalkMeters: originEndpoint.pointDistance.distance,
                        transferWalkMeters: edge.distance,
                        destinationWalkMeters: destinationEndpoint.pointDistance.distance,
                        totalMinutes: totalMinutes
                    )
                    let key = transferPathKey(candidate)
                    if candidateByKey[key].map({ candidate.totalMinutes < $0.totalMinutes }) ?? true {
                        candidateByKey[key] = candidate
                    }
                }
            }
        }

        return candidateByKey.values
            .sorted(by: transferCandidateSort)
            .prefix(limit)
            .map { $0 }
    }

    private func threeLegTransferCandidates(
        originRoutes: [TransferEndpoint],
        destinationRoutes: [TransferEndpoint],
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]],
        directWalkMinutes: Double,
        limit: Int
    ) -> [TransferPathCandidate] {
        guard limit > 0 else { return [] }

        let profiles = routeProfiles(stations: stations, uniqueStopsByRoute: uniqueStopsByRoute)
        let profilesByRoute = Dictionary(uniqueKeysWithValues: profiles.map { ($0.route, $0) })
        let index = transferPointIndex(for: profiles)

        var firstEdgesByOrigin: [LocalTransitRoute: [TransferEdge]] = [:]
        for endpoint in originRoutes {
            guard let profile = profilesByRoute[endpoint.route] else { continue }
            firstEdgesByOrigin[endpoint.route] = nearbyTransferEdges(
                from: profile,
                using: index,
                totalLimit: Self.maxNearbyTransferEdgesPerRoute,
                limitPerRoute: Self.maxNearbyTransferEdgesPerRoutePair
            )
        }

        var secondEdgesByMiddle: [LocalTransitRoute: [TransferEdge]] = [:]
        for endpoint in destinationRoutes {
            guard let profile = profilesByRoute[endpoint.route] else { continue }
            let incomingEdges = nearbyTransferEdges(
                from: profile,
                using: index,
                totalLimit: Self.maxNearbyTransferEdgesPerRoute,
                limitPerRoute: Self.maxNearbyTransferEdgesPerRoutePair
            )
            for edge in incomingEdges {
                let reversed = TransferEdge(
                    toRoute: endpoint.route,
                    fromPoint: edge.toPoint,
                    toPoint: edge.fromPoint,
                    distance: edge.distance
                )
                secondEdgesByMiddle[edge.toRoute, default: []].append(reversed)
            }
        }
        for route in secondEdgesByMiddle.keys {
            secondEdgesByMiddle[route] = secondEdgesByMiddle[route]?
                .sorted { $0.distance < $1.distance }
                .prefix(Self.maxNearbyTransferEdgesPerRoute)
                .map { $0 }
        }

        let destinationEndpointByRoute = Dictionary(uniqueKeysWithValues: destinationRoutes.map { ($0.route, $0) })
        var evaluatedCombinations = 0
        var candidateByKey: [String: TransferPathCandidate] = [:]
        for originEndpoint in originRoutes {
            for firstEdge in firstEdgesByOrigin[originEndpoint.route] ?? [] {
                let middleRoute = firstEdge.toRoute
                guard middleRoute != originEndpoint.route else { continue }
                for secondEdge in secondEdgesByMiddle[middleRoute] ?? [] {
                    guard evaluatedCombinations < Self.maxThreeLegCombinations else {
                        return candidateByKey.values.sorted(by: transferCandidateSort).prefix(limit).map { $0 }
                    }
                    evaluatedCombinations += 1

                    let destinationRoute = secondEdge.toRoute
                    guard
                        destinationRoute != originEndpoint.route,
                        destinationRoute != middleRoute,
                        let destinationEndpoint = destinationEndpointByRoute[destinationRoute],
                        let firstSegment = transferSegment(
                            route: originEndpoint.route,
                            from: originEndpoint.pointDistance.point,
                            to: firstEdge.fromPoint
                        ),
                        let middleSegment = transferSegment(
                            route: middleRoute,
                            from: firstEdge.toPoint,
                            to: secondEdge.fromPoint
                        ),
                        let finalSegment = transferSegment(
                            route: destinationRoute,
                            from: secondEdge.toPoint,
                            to: destinationEndpoint.pointDistance.point
                        )
                    else { continue }

                    let transferWalkMeters = firstEdge.distance + secondEdge.distance
                    let totalMinutes = originEndpoint.pointDistance.distance / walkingMetersPerMinute
                        + rideMinutes(for: firstSegment)
                        + boardingWaitMinutes(for: firstSegment.route)
                        + firstEdge.distance / walkingMetersPerMinute
                        + rideMinutes(for: middleSegment)
                        + boardingWaitMinutes(for: middleSegment.route)
                        + secondEdge.distance / walkingMetersPerMinute
                        + rideMinutes(for: finalSegment)
                        + boardingWaitMinutes(for: finalSegment.route)
                        + destinationEndpoint.pointDistance.distance / walkingMetersPerMinute
                    guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                    let candidate = TransferPathCandidate(
                        segments: [firstSegment, middleSegment, finalSegment],
                        originWalkMeters: originEndpoint.pointDistance.distance,
                        transferWalkMeters: transferWalkMeters,
                        destinationWalkMeters: destinationEndpoint.pointDistance.distance,
                        totalMinutes: totalMinutes
                    )
                    let key = transferPathKey(candidate)
                    if candidateByKey[key].map({ candidate.totalMinutes < $0.totalMinutes }) ?? true {
                        candidateByKey[key] = candidate
                    }
                }
            }
        }

        return candidateByKey.values
            .sorted(by: transferCandidateSort)
            .prefix(limit)
            .map { $0 }
    }

    private func transferPointIndex(for profiles: [RouteProfile]) -> TransferPointIndex {
        var grid: [String: [PointRef]] = [:]
        for profile in profiles {
            for point in profile.points {
                grid[bucketKey(point.coordinate, bucketSize: Self.transferBucketSize), default: []]
                    .append(PointRef(route: profile.route, point: point))
            }
        }
        return TransferPointIndex(grid: grid)
    }

    private func transferEdges(
        from profile: RouteProfile,
        to destinationProfile: RouteProfile,
        limit: Int
    ) -> [TransferEdge] {
        let index = transferPointIndex(for: [destinationProfile])
        return nearbyTransferEdges(
            from: profile,
            using: index,
            totalLimit: limit,
            limitPerRoute: limit
        )
    }

    private func nearbyTransferEdges(
        from profile: RouteProfile,
        using index: TransferPointIndex,
        totalLimit: Int,
        limitPerRoute: Int
    ) -> [TransferEdge] {
        guard totalLimit > 0, limitPerRoute > 0 else { return [] }

        var byRoute: [LocalTransitRoute: [TransferEdge]] = [:]
        for fromPoint in profile.points {
            let bucket = bucketCoordinate(fromPoint.coordinate, bucketSize: Self.transferBucketSize)
            for latitudeOffset in -1...1 {
                for longitudeOffset in -1...1 {
                    let key = "\(bucket.latitude + latitudeOffset):\(bucket.longitude + longitudeOffset)"
                    for ref in index.grid[key] ?? [] where ref.route != profile.route {
                        let distance = Distance.meters(
                            from: (fromPoint.coordinate.latitude, fromPoint.coordinate.longitude),
                            to: (ref.point.coordinate.latitude, ref.point.coordinate.longitude)
                        )
                        guard distance <= maxTransferWalkMeters else { continue }
                        byRoute[ref.route, default: []].append(
                            TransferEdge(
                                toRoute: ref.route,
                                fromPoint: fromPoint,
                                toPoint: ref.point,
                                distance: distance
                            )
                        )
                    }
                }
            }
        }

        return byRoute.values
            .flatMap { edges in
                edges
                    .sorted { $0.distance < $1.distance }
                    .prefix(limitPerRoute)
            }
            .sorted { $0.distance < $1.distance }
            .prefix(totalLimit)
            .map { $0 }
    }

    private func transferCandidateSort(
        _ lhs: TransferPathCandidate,
        _ rhs: TransferPathCandidate
    ) -> Bool {
        if lhs.segments.count != rhs.segments.count {
            return lhs.segments.count < rhs.segments.count
        }
        return lhs.totalMinutes < rhs.totalMinutes
    }

    private func closestPoint(
        in profile: RouteProfile,
        to point: (lat: Double, lon: Double),
        maxMeters: Double
    ) -> PointDistance? {
        profile.points
            .map { candidate in
                PointDistance(
                    point: candidate,
                    distance: Distance.meters(
                        from: point,
                        to: (candidate.coordinate.latitude, candidate.coordinate.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxMeters }
            .min { $0.distance < $1.distance }
    }

    private func transferSegment(
        route: LocalTransitRoute,
        from origin: TransitPoint,
        to destination: TransitPoint
    ) -> TransferPathSegment? {
        guard origin.id != destination.id else { return nil }
        let transitMeters = Distance.meters(
            from: (origin.coordinate.latitude, origin.coordinate.longitude),
            to: (destination.coordinate.latitude, destination.coordinate.longitude)
        )
        guard transitMeters >= minimumTransitMeters(for: route) else { return nil }
        return TransferPathSegment(
            route: route,
            boardingName: origin.name,
            alightingName: destination.name,
            boardingCoordinate: origin.coordinate,
            alightingCoordinate: destination.coordinate,
            transitMeters: transitMeters
        )
    }

    private func transitPoint(_ station: LStation) -> TransitPoint {
        TransitPoint(
            id: "station-\(station.id)",
            name: station.name,
            coordinate: PlannerCoordinate(latitude: station.latitude, longitude: station.longitude)
        )
    }

    private func transitPoint(_ stop: BusStop) -> TransitPoint {
        TransitPoint(
            id: "stop-\(stop.id)",
            name: stop.name,
            coordinate: PlannerCoordinate(latitude: stop.latitude, longitude: stop.longitude)
        )
    }

    private func bucketCoordinate(
        _ coordinate: PlannerCoordinate,
        bucketSize: Double
    ) -> (latitude: Int, longitude: Int) {
        (
            latitude: Int((coordinate.latitude / bucketSize).rounded(.down)),
            longitude: Int((coordinate.longitude / bucketSize).rounded(.down))
        )
    }

    private func bucketKey(_ coordinate: PlannerCoordinate, bucketSize: Double) -> String {
        let bucket = bucketCoordinate(coordinate, bucketSize: bucketSize)
        return "\(bucket.latitude):\(bucket.longitude)"
    }

    private func routeKey(_ route: LocalTransitRoute) -> String {
        switch route {
        case .bus(let route): return "bus:\(route)"
        case .train(let line): return "line:\(line.rawValue)"
        }
    }

    private func displayName(for route: LocalTransitRoute) -> String {
        switch route {
        case .bus(let route): return "Route \(route)"
        case .train(let line): return line.displayName
        }
    }

    private func resolution(for route: LocalTransitRoute) -> TransitResolution {
        switch route {
        case .bus(let route): return .bus(route)
        case .train(let line): return .line(line)
        }
    }

    private func boardingWaitMinutes(for route: LocalTransitRoute) -> Double {
        switch route {
        case .bus: return busBoardingWaitMinutes
        case .train: return lTrainBoardingWaitMinutes
        }
    }

    private func minimumTransitMeters(for route: LocalTransitRoute) -> Double {
        switch route {
        case .bus: return minBusTransitMeters
        case .train: return minTrainTransitMeters
        }
    }

    private func rideMinutes(for segment: TransferPathSegment) -> Double {
        switch segment.route {
        case .bus:
            return segment.transitMeters / busMetersPerMinute
        case .train:
            return segment.transitMeters / lTrainMetersPerMinute
        }
    }

    private func transferPathKey(_ candidate: TransferPathCandidate) -> String {
        candidate.segments.map { segment in
            [
                routeKey(segment.route),
                coordinateKey(segment.boardingCoordinate),
                coordinateKey(segment.alightingCoordinate),
            ].joined(separator: ":")
        }
        .joined(separator: "->")
    }

    private func makePlan(from candidate: TransferPathCandidate) -> TripPlan {
        guard let firstSegment = candidate.segments.first,
              let lastSegment = candidate.segments.last
        else {
            return TripPlan(
                flavor: .standard,
                summary: "Transit · estimated",
                expectedTravelTime: candidate.totalMinutes * 60,
                totalDistanceMeters: 0,
                legs: []
            )
        }

        var legs: [TripLeg] = [
            TripLeg(
                mode: .walking,
                distanceMeters: candidate.originWalkMeters,
                instructions: "Walk to \(firstSegment.boardingName)",
                transit: nil,
                endCoordinate: firstSegment.boardingCoordinate
            )
        ]

        for (index, segment) in candidate.segments.enumerated() {
            if index > 0 {
                let previous = candidate.segments[index - 1]
                let transferWalkMeters = Distance.meters(
                    from: (previous.alightingCoordinate.latitude, previous.alightingCoordinate.longitude),
                    to: (segment.boardingCoordinate.latitude, segment.boardingCoordinate.longitude)
                )
                legs.append(
                    TripLeg(
                        mode: .walking,
                        distanceMeters: transferWalkMeters,
                        instructions: "Walk to \(segment.boardingName)",
                        transit: nil,
                        startCoordinate: previous.alightingCoordinate,
                        endCoordinate: segment.boardingCoordinate
                    )
                )
            }

            let displayName = displayName(for: segment.route)
            legs.append(
                TripLeg(
                    mode: .transit,
                    distanceMeters: segment.transitMeters,
                    instructions: "Take \(displayName) from \(segment.boardingName) to \(segment.alightingName)",
                    transit: TransitLegInfo(rawName: displayName, resolution: resolution(for: segment.route)),
                    startCoordinate: segment.boardingCoordinate,
                    endCoordinate: segment.alightingCoordinate
                )
            )
        }

        legs.append(
            TripLeg(
                mode: .walking,
                distanceMeters: candidate.destinationWalkMeters,
                instructions: "Walk to your destination",
                transit: nil,
                startCoordinate: lastSegment.alightingCoordinate
            )
        )

        let transitDistance = candidate.segments.map(\.transitMeters).reduce(0, +)
        let totalDistance = candidate.originWalkMeters
            + candidate.transferWalkMeters
            + candidate.destinationWalkMeters
            + transitDistance
        return TripPlan(
            flavor: transferFlavor(for: candidate.segments),
            summary: transferSummary(for: candidate.segments),
            expectedTravelTime: candidate.totalMinutes * 60,
            totalDistanceMeters: totalDistance,
            legs: legs
        )
    }

    private func transferFlavor(for segments: [TransferPathSegment]) -> TripPlanFlavor {
        guard segments.count == 2 else { return .multiTransfer }
        switch (segments[0].route, segments[1].route) {
        case (.bus, .train):
            return .busToTrain
        case (.bus, .bus):
            return .busToBus
        case (.train, .bus):
            return .trainToBus
        default:
            return .multiTransfer
        }
    }

    private func transferSummary(for segments: [TransferPathSegment]) -> String {
        var seen: Set<String> = []
        let pieces = segments
            .map { displayName(for: $0.route) }
            .filter { seen.insert($0).inserted }
        return pieces.isEmpty ? "Transit · estimated" : "\(pieces.joined(separator: " + ")) · estimated"
    }

    private func makePlan(from candidate: Candidate, flavor: TripPlanFlavor) -> TripPlan {
        let originWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.originWalkMeters,
            instructions: "Walk to \(candidate.originStopName)",
            transit: nil
        )
        let transitLeg = TripLeg(
            mode: .transit,
            distanceMeters: candidate.transitMeters,
            instructions: "Take \(candidate.displayName) from \(candidate.originStopName) to \(candidate.destinationStopName)",
            transit: TransitLegInfo(rawName: candidate.displayName, resolution: candidate.resolution),
            startCoordinate: candidate.originStopCoordinate,
            endCoordinate: candidate.destinationStopCoordinate
        )
        let destWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.destinationWalkMeters,
            instructions: "Walk to your destination",
            transit: nil
        )
        let totalDistance = candidate.originWalkMeters + candidate.transitMeters + candidate.destinationWalkMeters
        let totalSeconds = candidate.totalMinutes * 60
        return TripPlan(
            flavor: flavor,
            summary: "\(candidate.displayName) · estimated",
            expectedTravelTime: totalSeconds,
            totalDistanceMeters: totalDistance,
            legs: [originWalkLeg, transitLeg, destWalkLeg]
        )
    }

    private func historyFirst(
        _ lhs: Candidate,
        _ rhs: Candidate,
        ranker: TripHistoryRanker
    ) -> Bool {
        let lhsScore = ranker.score(resolution: lhs.resolution)
        let rhsScore = ranker.score(resolution: rhs.resolution)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.totalMinutes < rhs.totalMinutes
    }

    private func historyFirst(
        _ lhs: TransferPathCandidate,
        _ rhs: TransferPathCandidate,
        ranker: TripHistoryRanker
    ) -> Bool {
        let lhsScore = ranker.score(resolutions: lhs.segments.map { resolution(for: $0.route) })
        let rhsScore = ranker.score(resolutions: rhs.segments.map { resolution(for: $0.route) })
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.totalMinutes < rhs.totalMinutes
    }

    private enum LocalTransitRoute: Hashable, Sendable {
        case bus(String)
        case train(LineColor)
    }

    private struct RouteProfile: Sendable {
        let route: LocalTransitRoute
        let points: [TransitPoint]
    }

    private struct TransitPoint: Hashable, Sendable {
        let id: String
        let name: String
        let coordinate: PlannerCoordinate
    }

    private struct PointDistance: Sendable {
        let point: TransitPoint
        let distance: Double
    }

    private struct PointRef: Sendable {
        let route: LocalTransitRoute
        let point: TransitPoint
    }

    private struct TransferPointIndex: Sendable {
        let grid: [String: [PointRef]]
    }

    private struct TransferEndpoint: Sendable {
        let route: LocalTransitRoute
        let pointDistance: PointDistance
    }

    private struct TransferEdge: Sendable {
        let toRoute: LocalTransitRoute
        let fromPoint: TransitPoint
        let toPoint: TransitPoint
        let distance: Double
    }

    private struct TransferPathCandidate: Sendable {
        let segments: [TransferPathSegment]
        let originWalkMeters: Double
        let transferWalkMeters: Double
        let destinationWalkMeters: Double
        let totalMinutes: Double
    }

    private struct TransferPathSegment: Sendable {
        let route: LocalTransitRoute
        let boardingName: String
        let alightingName: String
        let boardingCoordinate: PlannerCoordinate
        let alightingCoordinate: PlannerCoordinate
        let transitMeters: Double
    }

    private struct Candidate {
        let resolution: TransitResolution
        let displayName: String
        let originStopName: String
        let destinationStopName: String
        let originStopCoordinate: PlannerCoordinate
        let destinationStopCoordinate: PlannerCoordinate
        let originWalkMeters: Double
        let transitMeters: Double
        let destinationWalkMeters: Double
        let totalMinutes: Double
    }

    private func appendUniqueCandidate(
        _ candidate: Candidate,
        to candidates: inout [Candidate],
        seen: inout Set<String>
    ) {
        guard seen.insert(candidateKey(candidate)).inserted else { return }
        candidates.append(candidate)
    }

    private func candidateKey(_ candidate: Candidate) -> String {
        "\(resolutionKey(candidate.resolution)):\(coordinateKey(candidate.originStopCoordinate)):\(coordinateKey(candidate.destinationStopCoordinate))"
    }

    private func resolutionKey(_ resolution: TransitResolution) -> String {
        switch resolution {
        case .line(let line):
            return "line:\(line.rawValue)"
        case .bus(let route):
            return "bus:\(route)"
        case .metra(let route):
            return "metra:\(route)"
        case .unknown(let raw):
            return "unknown:\(raw)"
        }
    }

    private func coordinateKey(_ coordinate: PlannerCoordinate) -> String {
        let latitude = Int((coordinate.latitude * 1_000_000).rounded())
        let longitude = Int((coordinate.longitude * 1_000_000).rounded())
        return "\(latitude),\(longitude)"
    }

    private func nearest<Item>(
        in items: [Item],
        to point: (lat: Double, lon: Double),
        maxMeters: Double,
        limit: Int
    ) -> [(entry: Item, distance: Double)]
    where Item: HasGeocoordinate {
        items
            .map { item in
                (
                    entry: item,
                    distance: Distance.meters(from: point, to: (item.latitude, item.longitude))
                )
            }
            .filter { $0.distance <= maxMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(max(1, limit))
            .map { (entry: $0.entry, distance: $0.distance) }
    }

    private func closest<Item>(
        in items: [Item],
        to point: (lat: Double, lon: Double),
        maxMeters: Double
    ) -> (entry: Item, distance: Double)?
    where Item: HasGeocoordinate {
        nearest(in: items, to: point, maxMeters: maxMeters, limit: 1).first
    }
}

/// Internal seam so local proximity helpers can target either `LStation`
/// or `BusStop` without writing two near-identical implementations.
protocol HasGeocoordinate {
    var latitude: Double { get }
    var longitude: Double { get }
}

extension LStation: HasGeocoordinate {}
extension BusStop: HasGeocoordinate {}
extension MetraStation: HasGeocoordinate {}
