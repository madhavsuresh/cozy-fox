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
/// - Require the transit option to beat a direct walk by at least 15 %.
/// - Use straight-line distances; real route polylines are unavailable here.
public struct LocalTransitPlanner: Sendable {
    public let walkingMetersPerMinute: Double
    public let lTrainMetersPerMinute: Double
    public let busMetersPerMinute: Double
    public let lTrainBoardingWaitMinutes: Double
    public let busBoardingWaitMinutes: Double
    public let minimumTripSavingsFactor: Double
    public let maxStationWalkMeters: Double
    public let maxStopWalkMeters: Double
    public let minDirectWalkMeters: Double
    public let minBusTransitMeters: Double

    public init(
        walkingMetersPerMinute: Double = 84,
        lTrainMetersPerMinute: Double = 670,
        busMetersPerMinute: Double = 270,
        lTrainBoardingWaitMinutes: Double = 3,
        busBoardingWaitMinutes: Double = 5,
        minimumTripSavingsFactor: Double = 0.85,
        maxStationWalkMeters: Double = 1_500,
        maxStopWalkMeters: Double = 750,
        minDirectWalkMeters: Double = 800,
        minBusTransitMeters: Double = 500
    ) {
        self.walkingMetersPerMinute = walkingMetersPerMinute
        self.lTrainMetersPerMinute = lTrainMetersPerMinute
        self.busMetersPerMinute = busMetersPerMinute
        self.lTrainBoardingWaitMinutes = lTrainBoardingWaitMinutes
        self.busBoardingWaitMinutes = busBoardingWaitMinutes
        self.minimumTripSavingsFactor = minimumTripSavingsFactor
        self.maxStationWalkMeters = maxStationWalkMeters
        self.maxStopWalkMeters = maxStopWalkMeters
        self.minDirectWalkMeters = minDirectWalkMeters
        self.minBusTransitMeters = minBusTransitMeters
    }

    public func plan(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate,
        stations: [LStation] = LStationCatalog.all,
        busStops: [BusStop] = BusStopCatalog.all
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
                originWalkMeters: originStation.distance,
                transitMeters: transitMeters,
                destinationWalkMeters: destStation.distance,
                totalMinutes: totalMinutes
            )
            if bestTrain == nil || totalMinutes < bestTrain!.totalMinutes {
                bestTrain = candidate
            }
        }

        // Bus side: collect every viable route, then surface up to two
        // tradeoff picks — one minimizing time on the bus (more walking) and
        // one minimizing walk distance (more time on the bus). If both
        // tradeoffs land on the same route, only the shortest-ride one is
        // shown — pinning either would set the same `pinnedBusRoute` anyway.
        var busCandidates: [Candidate] = []
        let byRoute = Dictionary(grouping: busStops, by: \.route)
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
        if let shortestRide {
            plans.append(makePlan(from: shortestRide, flavor: .busShortestRide))
        }
        if let shortestWalk, shortestWalk.resolution != shortestRide?.resolution {
            plans.append(makePlan(from: shortestWalk, flavor: .busShortestWalk))
        }
        return plans
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
            transit: TransitLegInfo(rawName: candidate.displayName, resolution: candidate.resolution)
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

    private struct Candidate {
        let resolution: TransitResolution
        let displayName: String
        let originStopName: String
        let destinationStopName: String
        let originWalkMeters: Double
        let transitMeters: Double
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
