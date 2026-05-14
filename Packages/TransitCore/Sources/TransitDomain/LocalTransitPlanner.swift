import Foundation
import TransitModels

/// Builds a single-transit-leg trip plan from origin → destination using only
/// the bundled CTA catalog (`LStationCatalog`, `BusStopCatalog`). Used as a
/// fallback when `MKDirections.calculate(.transit)` returns "operation
/// couldn't be completed" — which is the documented behavior of Apple's
/// transit-routing API ("Only supported for ETA calculations") in many
/// regions/builds.
///
/// Heuristic, not a real router:
/// - Score every L line and every bus route by `originWalk + transit + destWalk`
///   minutes, using ballpark speeds (~5 km/h walking, ~40 km/h L, ~16 km/h bus).
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
        minTrainTransitMeters: Double = 800
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

        // L-line side: take the fastest single line. The user only gets one
        // train option (they can change line via the existing chips picker on
        // the dashboard).
        var bestTrain: Candidate?

        for line in LineColor.allCases {
            let onLine = stations.filter { $0.servedLines.contains(line) }
            guard
                let originStation = closest(in: onLine, to: originPair, maxMeters: maxStationWalkMeters),
                let destStation = closest(in: onLine, to: destinationPair, maxMeters: maxStationWalkMeters),
                originStation.entry.id != destStation.entry.id
            else { continue }

            let transitMeters = Distance.meters(
                from: (originStation.entry.latitude, originStation.entry.longitude),
                to: (destStation.entry.latitude, destStation.entry.longitude)
            )
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
            if bestTrain == nil || totalMinutes < bestTrain!.totalMinutes {
                bestTrain = candidate
            }
        }

        var bestMetra: Candidate?
        for line in MetraStationCatalog.routes {
            let onLine = metraStations.filter { $0.servedRoutes.contains(line.id) }
            guard
                let originStation = closest(in: onLine, to: originPair, maxMeters: maxMetraStationWalkMeters),
                let destStation = closest(in: onLine, to: destinationPair, maxMeters: maxMetraStationWalkMeters),
                originStation.entry.id != destStation.entry.id
            else { continue }

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
            if bestMetra == nil || totalMinutes < bestMetra!.totalMinutes {
                bestMetra = candidate
            }
        }

        // Bus side: collect every viable route, then surface up to two
        // tradeoff picks — one minimizing time on the bus (more walking) and
        // one minimizing walk distance (more time on the bus). If both
        // tradeoffs land on the same route, only the shortest-ride one is
        // shown — pinning either would set the same `pinnedBusRoute` anyway.
        let byRoute = Dictionary(grouping: busStops, by: \.route)
        let uniqueStopsByRoute = byRoute.mapValues { stops in
            var seen: Set<Int> = []
            return stops.filter { seen.insert($0.id).inserted }
        }
        let originStopByRoute: [String: (entry: BusStop, distance: Double)] = uniqueStopsByRoute.compactMapValues {
            closest(in: $0, to: originPair, maxMeters: maxStopWalkMeters)
        }

        let busToTrain = bestBusToTrainCandidate(
            origin: originPair,
            destination: destinationPair,
            directWalkMinutes: directWalkMinutes,
            stations: stations,
            uniqueStopsByRoute: uniqueStopsByRoute,
            originStopByRoute: originStopByRoute
        )

        var busCandidates: [Candidate] = []
        for (route, stops) in byRoute {
            var seen: Set<Int> = []
            let unique = stops.filter { seen.insert($0.id).inserted }

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

            busCandidates.append(Candidate(
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
            ))
        }

        let shortestRide = busCandidates.min { $0.transitMeters < $1.transitMeters }
        let shortestWalk = busCandidates.min {
            ($0.originWalkMeters + $0.destinationWalkMeters)
                < ($1.originWalkMeters + $1.destinationWalkMeters)
        }

        var plans: [TripPlan] = []
        if let bestTrain { plans.append(makePlan(from: bestTrain, flavor: .train)) }
        if let busToTrain { plans.append(makePlan(from: busToTrain)) }
        if let bestMetra { plans.append(makePlan(from: bestMetra, flavor: .metra)) }
        if let shortestRide {
            plans.append(makePlan(from: shortestRide, flavor: .busShortestRide))
        }
        if let shortestWalk, shortestWalk.resolution != shortestRide?.resolution {
            plans.append(makePlan(from: shortestWalk, flavor: .busShortestWalk))
        }
        return plans
    }

    private func bestBusToTrainCandidate(
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        directWalkMinutes: Double,
        stations: [LStation],
        uniqueStopsByRoute: [String: [BusStop]],
        originStopByRoute: [String: (entry: BusStop, distance: Double)]
    ) -> BusToTrainCandidate? {
        var best: BusToTrainCandidate?

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

                    if best == nil || candidate.totalMinutes < best!.totalMinutes {
                        best = candidate
                    }
                }
            }
        }

        return best
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

    private func closest<Item>(
        in items: [Item],
        to point: (lat: Double, lon: Double),
        maxMeters: Double
    ) -> (entry: Item, distance: Double)?
    where Item: HasGeocoordinate {
        var best: (entry: Item, distance: Double)?
        for item in items {
            let d = Distance.meters(from: point, to: (item.latitude, item.longitude))
            if d > maxMeters { continue }
            if best == nil || d < best!.distance {
                best = (item, d)
            }
        }
        return best
    }
}

/// Internal seam so `closest(in:to:maxMeters:)` can target either `LStation`
/// or `BusStop` without writing two near-identical implementations.
protocol HasGeocoordinate {
    var latitude: Double { get }
    var longitude: Double { get }
}

extension LStation: HasGeocoordinate {}
extension BusStop: HasGeocoordinate {}
extension MetraStation: HasGeocoordinate {}
