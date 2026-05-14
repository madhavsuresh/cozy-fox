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
/// - Also score bus-to-L access routes, so options like "65 to Grand, then
///   Blue Line" can appear when walking or biking to the train is not the
///   only reasonable way to start the trip.
/// - Require the transit option to beat a direct walk by at least 15 %.
/// - Use straight-line distances; real route polylines are unavailable here.
public struct LocalTransitPlanner: Sendable {
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
        self.maxMetraPlans = maxMetraPlans
    }

    public func plan(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate,
        stations: [LStation] = LStationCatalog.all,
        busStops: [BusStop] = BusStopCatalog.all,
        metraStations: [MetraStation] = MetraStationCatalog.all
    ) -> [TripPlan] {
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

        let busToTrainCandidates = busToTrainCandidates(
            origin: originPair,
            destination: destinationPair,
            directWalkMinutes: directWalkMinutes,
            stations: stations,
            uniqueStopsByRoute: uniqueStopsByRoute,
            originStopByRoute: originStopByRoute
        )
        let trainToBusCandidates = trainToBusCandidates(
            origin: originPair,
            destination: destinationPair,
            directWalkMinutes: directWalkMinutes,
            stations: stations,
            uniqueStopsByRoute: uniqueStopsByRoute,
            destinationStopByRoute: destinationStopByRoute
        )

        var busCandidates: [Candidate] = []
        var busKeys: Set<String> = []
        for (route, unique) in uniqueStopsByRoute {
            guard
                let originStop = closest(in: unique, to: originPair, maxMeters: maxStopWalkMeters),
                let destStop = closest(in: unique, to: destinationPair, maxMeters: maxStopWalkMeters),
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

        if let shortestRide {
            appendBusCandidate(shortestRide, flavor: .busShortestRide)
        }
        if let shortestWalk, shortestWalk.resolution != shortestRide?.resolution {
            appendBusCandidate(shortestWalk, flavor: .busShortestWalk)
        }
        for candidate in busCandidates.sorted(by: { $0.totalMinutes < $1.totalMinutes }) {
            appendBusCandidate(candidate, flavor: .busShortestRide)
        }

        var plans: [TripPlan] = []
        for candidate in trainCandidates.sorted(by: { $0.totalMinutes < $1.totalMinutes }).prefix(max(0, maxTrainPlans)) {
            plans.append(makePlan(from: candidate, flavor: .train))
        }
        for candidate in busToTrainCandidates.prefix(max(0, maxBusToTrainPlans)) {
            plans.append(makePlan(from: candidate))
        }
        for candidate in trainToBusCandidates.prefix(max(0, maxBusToTrainPlans)) {
            plans.append(makePlan(from: candidate))
        }
        for candidate in metraCandidates.sorted(by: { $0.totalMinutes < $1.totalMinutes }).prefix(max(0, maxMetraPlans)) {
            plans.append(makePlan(from: candidate, flavor: .metra))
        }
        for entry in selectedBusCandidates {
            plans.append(makePlan(from: entry.candidate, flavor: entry.flavor))
        }
        return plans
    }

    private func busToTrainCandidates(
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        directWalkMinutes: Double,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]],
        originStopByRoute: [String: (entry: BusStop, distance: Double)]
    ) -> [BusToTrainCandidate] {
        var candidates: [BusToTrainCandidate] = []
        var seen: Set<String> = []

        for line in LineColor.allCases {
            let onLine = stations.filter { $0.servedLines.contains(line) }
            guard let destinationStation = closest(
                in: onLine,
                to: destination,
                maxMeters: maxStationWalkMeters
            ) else { continue }

            for originStation in onLine where originStation.id != destinationStation.entry.id {
                let trainMeters = Distance.meters(
                    from: (originStation.latitude, originStation.longitude),
                    to: (destinationStation.entry.latitude, destinationStation.entry.longitude)
                )
                guard trainMeters >= minTrainTransitMeters else { continue }

                for (route, stops) in uniqueStopsByRoute {
                    guard let originStop = originStopByRoute[route] else { continue }
                    guard let transferStop = closest(
                        in: stops,
                        to: (originStation.latitude, originStation.longitude),
                        maxMeters: maxTransferWalkMeters
                    ) else { continue }
                    guard originStop.entry.id != transferStop.entry.id else { continue }

                    let busMeters = Distance.meters(
                        from: (originStop.entry.latitude, originStop.entry.longitude),
                        to: (transferStop.entry.latitude, transferStop.entry.longitude)
                    )
                    guard busMeters >= minBusTransitMeters else { continue }

                    let walkMinutes = originStop.distance / walkingMetersPerMinute
                        + transferStop.distance / walkingMetersPerMinute
                        + destinationStation.distance / walkingMetersPerMinute
                    let rideMinutes = busMeters / busMetersPerMinute
                        + trainMeters / lTrainMetersPerMinute
                    let totalMinutes = walkMinutes
                        + rideMinutes
                        + busBoardingWaitMinutes
                        + lTrainBoardingWaitMinutes

                    guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                    let candidate = BusToTrainCandidate(
                        busRoute: route,
                        trainLine: line,
                        originBusStopName: originStop.entry.name,
                        transferBusStopName: transferStop.entry.name,
                        originTrainStationName: originStation.name,
                        destinationTrainStationName: destinationStation.entry.name,
                        originBusStopCoordinate: PlannerCoordinate(
                            latitude: originStop.entry.latitude,
                            longitude: originStop.entry.longitude
                        ),
                        transferBusStopCoordinate: PlannerCoordinate(
                            latitude: transferStop.entry.latitude,
                            longitude: transferStop.entry.longitude
                        ),
                        originTrainStationCoordinate: PlannerCoordinate(
                            latitude: originStation.latitude,
                            longitude: originStation.longitude
                        ),
                        destinationTrainStationCoordinate: PlannerCoordinate(
                            latitude: destinationStation.entry.latitude,
                            longitude: destinationStation.entry.longitude
                        ),
                        originWalkMeters: originStop.distance,
                        busMeters: busMeters,
                        transferWalkMeters: transferStop.distance,
                        trainMeters: trainMeters,
                        destinationWalkMeters: destinationStation.distance,
                        totalMinutes: totalMinutes
                    )

                    let key = busToTrainKey(candidate)
                    guard seen.insert(key).inserted else { continue }
                    candidates.append(candidate)
                }
            }
        }

        return candidates.sorted { $0.totalMinutes < $1.totalMinutes }
    }

    private func trainToBusCandidates(
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        directWalkMinutes: Double,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]],
        destinationStopByRoute: [String: (entry: BusStop, distance: Double)]
    ) -> [TrainToBusCandidate] {
        var candidates: [TrainToBusCandidate] = []
        var seen: Set<String> = []

        for line in LineColor.allCases {
            let onLine = stations.filter { $0.servedLines.contains(line) }
            let candidateLimit = max(2, maxTrainPlans)
            let originStations = nearest(
                in: onLine,
                to: origin,
                maxMeters: maxStationWalkMeters,
                limit: candidateLimit
            )

            for originStation in originStations {
                for transferStation in onLine where transferStation.id != originStation.entry.id {
                    let trainMeters = Distance.meters(
                        from: (originStation.entry.latitude, originStation.entry.longitude),
                        to: (transferStation.latitude, transferStation.longitude)
                    )
                    guard trainMeters >= minTrainTransitMeters else { continue }

                    for (route, stops) in uniqueStopsByRoute {
                        guard let destinationStop = destinationStopByRoute[route] else { continue }
                        guard let transferStop = closest(
                            in: stops,
                            to: (transferStation.latitude, transferStation.longitude),
                            maxMeters: maxTransferWalkMeters
                        ) else { continue }
                        guard transferStop.entry.id != destinationStop.entry.id else { continue }

                        let busMeters = Distance.meters(
                            from: (transferStop.entry.latitude, transferStop.entry.longitude),
                            to: (destinationStop.entry.latitude, destinationStop.entry.longitude)
                        )
                        guard busMeters >= minBusTransitMeters else { continue }

                        let walkMinutes = originStation.distance / walkingMetersPerMinute
                            + transferStop.distance / walkingMetersPerMinute
                            + destinationStop.distance / walkingMetersPerMinute
                        let rideMinutes = trainMeters / lTrainMetersPerMinute
                            + busMeters / busMetersPerMinute
                        let totalMinutes = walkMinutes
                            + rideMinutes
                            + lTrainBoardingWaitMinutes
                            + busBoardingWaitMinutes

                        guard totalMinutes < directWalkMinutes * minimumTripSavingsFactor else { continue }

                        let candidate = TrainToBusCandidate(
                            trainLine: line,
                            busRoute: route,
                            originTrainStationName: originStation.entry.name,
                            transferTrainStationName: transferStation.name,
                            transferBusStopName: transferStop.entry.name,
                            destinationBusStopName: destinationStop.entry.name,
                            originTrainStationCoordinate: PlannerCoordinate(
                                latitude: originStation.entry.latitude,
                                longitude: originStation.entry.longitude
                            ),
                            transferTrainStationCoordinate: PlannerCoordinate(
                                latitude: transferStation.latitude,
                                longitude: transferStation.longitude
                            ),
                            transferBusStopCoordinate: PlannerCoordinate(
                                latitude: transferStop.entry.latitude,
                                longitude: transferStop.entry.longitude
                            ),
                            destinationBusStopCoordinate: PlannerCoordinate(
                                latitude: destinationStop.entry.latitude,
                                longitude: destinationStop.entry.longitude
                            ),
                            originWalkMeters: originStation.distance,
                            trainMeters: trainMeters,
                            transferWalkMeters: transferStop.distance,
                            busMeters: busMeters,
                            destinationWalkMeters: destinationStop.distance,
                            totalMinutes: totalMinutes
                        )

                        let key = trainToBusKey(candidate)
                        guard seen.insert(key).inserted else { continue }
                        candidates.append(candidate)
                    }
                }
            }
        }

        return candidates.sorted { $0.totalMinutes < $1.totalMinutes }
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

    private func makePlan(from candidate: BusToTrainCandidate) -> TripPlan {
        let originWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.originWalkMeters,
            instructions: "Walk to \(candidate.originBusStopName)",
            transit: nil
        )
        let busLeg = TripLeg(
            mode: .transit,
            distanceMeters: candidate.busMeters,
            instructions: "Take Route \(candidate.busRoute) to \(candidate.transferBusStopName)",
            transit: TransitLegInfo(rawName: "Route \(candidate.busRoute)", resolution: .bus(candidate.busRoute)),
            startCoordinate: candidate.originBusStopCoordinate,
            endCoordinate: candidate.transferBusStopCoordinate
        )
        let transferWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.transferWalkMeters,
            instructions: "Walk to \(candidate.originTrainStationName)",
            transit: nil,
            startCoordinate: candidate.transferBusStopCoordinate,
            endCoordinate: candidate.originTrainStationCoordinate
        )
        let trainLeg = TripLeg(
            mode: .transit,
            distanceMeters: candidate.trainMeters,
            instructions: "Take \(candidate.trainLine.displayName) from \(candidate.originTrainStationName) to \(candidate.destinationTrainStationName)",
            transit: TransitLegInfo(rawName: candidate.trainLine.displayName, resolution: .line(candidate.trainLine)),
            startCoordinate: candidate.originTrainStationCoordinate,
            endCoordinate: candidate.destinationTrainStationCoordinate
        )
        let destWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.destinationWalkMeters,
            instructions: "Walk to your destination",
            transit: nil,
            startCoordinate: candidate.destinationTrainStationCoordinate
        )
        let totalDistance = candidate.originWalkMeters
            + candidate.busMeters
            + candidate.transferWalkMeters
            + candidate.trainMeters
            + candidate.destinationWalkMeters
        let totalSeconds = candidate.totalMinutes * 60
        return TripPlan(
            flavor: .busToTrain,
            summary: "Route \(candidate.busRoute) + \(candidate.trainLine.displayName) · estimated",
            expectedTravelTime: totalSeconds,
            totalDistanceMeters: totalDistance,
            legs: [originWalkLeg, busLeg, transferWalkLeg, trainLeg, destWalkLeg]
        )
    }

    private func makePlan(from candidate: TrainToBusCandidate) -> TripPlan {
        let originWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.originWalkMeters,
            instructions: "Walk to \(candidate.originTrainStationName)",
            transit: nil
        )
        let trainLeg = TripLeg(
            mode: .transit,
            distanceMeters: candidate.trainMeters,
            instructions: "Take \(candidate.trainLine.displayName) from \(candidate.originTrainStationName) to \(candidate.transferTrainStationName)",
            transit: TransitLegInfo(rawName: candidate.trainLine.displayName, resolution: .line(candidate.trainLine)),
            startCoordinate: candidate.originTrainStationCoordinate,
            endCoordinate: candidate.transferTrainStationCoordinate
        )
        let transferWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.transferWalkMeters,
            instructions: "Walk to \(candidate.transferBusStopName)",
            transit: nil,
            startCoordinate: candidate.transferTrainStationCoordinate,
            endCoordinate: candidate.transferBusStopCoordinate
        )
        let busLeg = TripLeg(
            mode: .transit,
            distanceMeters: candidate.busMeters,
            instructions: "Take Route \(candidate.busRoute) to \(candidate.destinationBusStopName)",
            transit: TransitLegInfo(rawName: "Route \(candidate.busRoute)", resolution: .bus(candidate.busRoute)),
            startCoordinate: candidate.transferBusStopCoordinate,
            endCoordinate: candidate.destinationBusStopCoordinate
        )
        let destWalkLeg = TripLeg(
            mode: .walking,
            distanceMeters: candidate.destinationWalkMeters,
            instructions: "Walk to your destination",
            transit: nil,
            startCoordinate: candidate.destinationBusStopCoordinate
        )
        let totalDistance = candidate.originWalkMeters
            + candidate.trainMeters
            + candidate.transferWalkMeters
            + candidate.busMeters
            + candidate.destinationWalkMeters
        let totalSeconds = candidate.totalMinutes * 60
        return TripPlan(
            flavor: .trainToBus,
            summary: "\(candidate.trainLine.displayName) + Route \(candidate.busRoute) · estimated",
            expectedTravelTime: totalSeconds,
            totalDistanceMeters: totalDistance,
            legs: [originWalkLeg, trainLeg, transferWalkLeg, busLeg, destWalkLeg]
        )
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

    private struct BusToTrainCandidate {
        let busRoute: String
        let trainLine: LineColor
        let originBusStopName: String
        let transferBusStopName: String
        let originTrainStationName: String
        let destinationTrainStationName: String
        let originBusStopCoordinate: PlannerCoordinate
        let transferBusStopCoordinate: PlannerCoordinate
        let originTrainStationCoordinate: PlannerCoordinate
        let destinationTrainStationCoordinate: PlannerCoordinate
        let originWalkMeters: Double
        let busMeters: Double
        let transferWalkMeters: Double
        let trainMeters: Double
        let destinationWalkMeters: Double
        let totalMinutes: Double
    }

    private struct TrainToBusCandidate {
        let trainLine: LineColor
        let busRoute: String
        let originTrainStationName: String
        let transferTrainStationName: String
        let transferBusStopName: String
        let destinationBusStopName: String
        let originTrainStationCoordinate: PlannerCoordinate
        let transferTrainStationCoordinate: PlannerCoordinate
        let transferBusStopCoordinate: PlannerCoordinate
        let destinationBusStopCoordinate: PlannerCoordinate
        let originWalkMeters: Double
        let trainMeters: Double
        let transferWalkMeters: Double
        let busMeters: Double
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

    private func busToTrainKey(_ candidate: BusToTrainCandidate) -> String {
        [
            "bus:\(candidate.busRoute)",
            "line:\(candidate.trainLine.rawValue)",
            coordinateKey(candidate.originBusStopCoordinate),
            coordinateKey(candidate.transferBusStopCoordinate),
            coordinateKey(candidate.originTrainStationCoordinate),
            coordinateKey(candidate.destinationTrainStationCoordinate),
        ].joined(separator: ":")
    }

    private func trainToBusKey(_ candidate: TrainToBusCandidate) -> String {
        [
            "line:\(candidate.trainLine.rawValue)",
            "bus:\(candidate.busRoute)",
            coordinateKey(candidate.originTrainStationCoordinate),
            coordinateKey(candidate.transferTrainStationCoordinate),
            coordinateKey(candidate.transferBusStopCoordinate),
            coordinateKey(candidate.destinationBusStopCoordinate),
        ].joined(separator: ":")
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
