import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("LocalTransitPlanner")
struct LocalTransitPlannerTests {
    /// Two synthetic Blue Line stations 5 km apart; origin and destination are
    /// each ~200 m from a station. Should produce a train plan.
    @Test func producesTrainPlanWhenStationsBracketTheTrip() throws {
        let stations: [LStation] = [
            LStation(id: 1, name: "Origin Station", latitude: 41.880, longitude: -87.700,
                     servedLines: [.blue]),
            LStation(id: 2, name: "Dest Station", latitude: 41.880, longitude: -87.640,
                     servedLines: [.blue]),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.881, longitude: -87.701),
            to: PlannerCoordinate(latitude: 41.881, longitude: -87.639),
            stations: stations,
            busStops: [],
            metraStations: []
        )
        let train = try #require(plans.first)
        let resolution = train.legs.first(where: { $0.mode == .transit })?.transit?.resolution
        #expect(resolution == .line(.blue))
        #expect(train.legs.count == 3)
        // No bus stops supplied — only the train plan should come back.
        #expect(plans.count == 1)
    }

    @Test func producesMultipleTrainPlansForDifferentBoardingStations() throws {
        let stations: [LStation] = [
            LStation(id: 1, name: "Closest Origin", latitude: 41.880, longitude: -87.700,
                     servedLines: [.blue]),
            LStation(id: 2, name: "Bikeable Origin", latitude: 41.880, longitude: -87.690,
                     servedLines: [.blue]),
            LStation(id: 3, name: "Closest Destination", latitude: 41.880, longitude: -87.640,
                     servedLines: [.blue]),
            LStation(id: 4, name: "Alternate Destination", latitude: 41.880, longitude: -87.650,
                     servedLines: [.blue]),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: stations,
            busStops: [],
            metraStations: []
        )
        let trainPlans = plans.filter { $0.flavor == .train }
        #expect(trainPlans.count >= 2)
        let boardingInstructions = Set(trainPlans.compactMap {
            $0.legs.first(where: { $0.mode == .transit })?.instructions
        })
        #expect(boardingInstructions.count >= 2)
    }

    /// No L stations in range, but a #22 bus route with stops bracketing the
    /// trip. Should produce just a bus plan.
    @Test func producesBusPlanWhenOnlyBusRoutesAreReachable() throws {
        let stops: [BusStop] = [
            BusStop(id: 100, route: "22", name: "Origin Stop",
                    latitude: 41.880, longitude: -87.700, directionLabel: "Northbound"),
            BusStop(id: 101, route: "22", name: "Dest Stop",
                    latitude: 41.880, longitude: -87.660, directionLabel: "Northbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.701),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.659),
            stations: [],
            busStops: stops,
            metraStations: []
        )
        let bus = try #require(plans.first)
        let resolution = bus.legs.first(where: { $0.mode == .transit })?.transit?.resolution
        #expect(resolution == .bus("22"))
        #expect(plans.count == 1)
    }

    /// When both an L line and a bus route are feasible, surface both — the
    /// dashboard wants to show the user both options side by side. With only
    /// one bus route in the fixture, we expect 1 train + 1 bus = 2 plans.
    @Test func producesTrainAndOneBusWhenOnlyOneBusRouteViable() {
        let stations: [LStation] = [
            LStation(id: 1, name: "Origin Station", latitude: 41.880, longitude: -87.700,
                     servedLines: [.red]),
            LStation(id: 2, name: "Dest Station", latitude: 41.880, longitude: -87.640,
                     servedLines: [.red]),
        ]
        let stops: [BusStop] = [
            BusStop(id: 100, route: "22", name: "Origin Stop",
                    latitude: 41.880, longitude: -87.701, directionLabel: "Northbound"),
            BusStop(id: 101, route: "22", name: "Dest Stop",
                    latitude: 41.880, longitude: -87.642, directionLabel: "Northbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: stations,
            busStops: stops,
            metraStations: []
        )
        #expect(plans.count == 2)
        #expect(plans.first?.flavor == .train)
        #expect(plans.last?.flavor == .busShortestRide)
    }

    @Test func producesBusToTrainPlanWhenBusFeedsTrainStation() throws {
        let stations: [LStation] = [
            LStation(id: 1, name: "Transfer Station", latitude: 41.880, longitude: -87.680,
                     servedLines: [.blue]),
            LStation(id: 2, name: "Destination Station", latitude: 41.880, longitude: -87.641,
                     servedLines: [.blue]),
        ]
        let stops: [BusStop] = [
            BusStop(id: 100, route: "65", name: "Origin Bus Stop",
                    latitude: 41.880, longitude: -87.699, directionLabel: "Westbound"),
            BusStop(id: 101, route: "65", name: "Transfer Bus Stop",
                    latitude: 41.880, longitude: -87.6805, directionLabel: "Westbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: stations,
            busStops: stops,
            metraStations: []
        )
        let plan = try #require(plans.first)
        #expect(plan.flavor == .busToTrain)
        #expect(plans.count == 1)
        let transitResolutions = plan.legs.compactMap(\.transit?.resolution)
        #expect(transitResolutions == [.bus("65"), .line(.blue)])
        #expect(plan.legs.count == 5)
    }

    @Test func producesTrainToBusPlanWhenTrainFeedsBusRoute() throws {
        let stations: [LStation] = [
            LStation(id: 1, name: "Origin Station", latitude: 41.880, longitude: -87.700,
                     servedLines: [.red]),
            LStation(id: 2, name: "Transfer Station", latitude: 41.900, longitude: -87.700,
                     servedLines: [.red]),
        ]
        let stops: [BusStop] = [
            BusStop(id: 100, route: "77", name: "Transfer Bus Stop",
                    latitude: 41.9005, longitude: -87.700, directionLabel: "Eastbound"),
            BusStop(id: 101, route: "77", name: "Destination Bus Stop",
                    latitude: 41.920, longitude: -87.700, directionLabel: "Eastbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.879, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.9205, longitude: -87.700),
            stations: stations,
            busStops: stops,
            metraStations: []
        )
        let plan = try #require(plans.first)
        #expect(plan.flavor == .trainToBus)
        #expect(plans.count == 1)
        let transitResolutions = plan.legs.compactMap(\.transit?.resolution)
        #expect(transitResolutions == [.line(.red), .bus("77")])
        #expect(plan.legs.count == 5)
    }

    @Test func producesBusToBusPlanWhenBusRoutesConnectAtTransfer() throws {
        let stops: [BusStop] = [
            BusStop(id: 100, route: "151", name: "Origin Northbound Stop",
                    latitude: 41.880, longitude: -87.700, directionLabel: "Northbound"),
            BusStop(id: 101, route: "151", name: "Belmont Transfer Stop",
                    latitude: 41.900, longitude: -87.700, directionLabel: "Northbound"),
            BusStop(id: 200, route: "77", name: "Belmont Westbound Stop",
                    latitude: 41.9004, longitude: -87.700, directionLabel: "Westbound"),
            BusStop(id: 201, route: "77", name: "Avondale Stop",
                    latitude: 41.9004, longitude: -87.640, directionLabel: "Westbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.879, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.9004, longitude: -87.639),
            stations: [],
            busStops: stops,
            metraStations: []
        )
        let plan = try #require(plans.first)
        #expect(plan.flavor == .busToBus)
        #expect(plans.count == 1)
        let transitResolutions = plan.legs.compactMap(\.transit?.resolution)
        #expect(transitResolutions == [.bus("151"), .bus("77")])
        #expect(plan.legs.count == 5)
    }

    @Test func producesMultipleBusToTrainPlansWhenSeveralBusesFeedStations() throws {
        let stations: [LStation] = [
            LStation(id: 1, name: "Transfer Station", latitude: 41.880, longitude: -87.680,
                     servedLines: [.blue]),
            LStation(id: 2, name: "Destination Station", latitude: 41.880, longitude: -87.641,
                     servedLines: [.blue]),
        ]
        let stops: [BusStop] = [
            BusStop(id: 100, route: "65", name: "65 Origin",
                    latitude: 41.880, longitude: -87.699, directionLabel: "Westbound"),
            BusStop(id: 101, route: "65", name: "65 Transfer",
                    latitude: 41.880, longitude: -87.6805, directionLabel: "Westbound"),
            BusStop(id: 200, route: "66", name: "66 Origin",
                    latitude: 41.880, longitude: -87.7005, directionLabel: "Westbound"),
            BusStop(id: 201, route: "66", name: "66 Transfer",
                    latitude: 41.880, longitude: -87.6810, directionLabel: "Westbound"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: stations,
            busStops: stops,
            metraStations: []
        )
        let busToTrainPlans = plans.filter { $0.flavor == .busToTrain }
        #expect(busToTrainPlans.count >= 2)
        let busRoutes = Set(busToTrainPlans.compactMap { plan -> String? in
            guard case .bus(let route) = plan.legs.compactMap(\.transit?.resolution).first else {
                return nil
            }
            return route
        })
        #expect(busRoutes.contains("65"))
        #expect(busRoutes.contains("66"))
    }

    /// Two bus routes where each represents a different tradeoff: route 22
    /// requires more walking but a shorter bus ride; route 7 has closer stops
    /// but takes the bus further to its alighting stop. Both should appear,
    /// labeled by their respective flavor.
    @Test func producesTwoBusPlansWhenTradeoffsDiffer() {
        // Origin: 41.880, -87.700. Destination: 41.880, -87.640.
        // Route 22: stops at 41.880,-87.698 (200m origin walk) and
        //          41.880,-87.642 (200m destination walk) — bus ride ~4.7km.
        // Route 7: stops at 41.880,-87.7008 (62m origin walk) and
        //         41.880,-87.6395 (45m destination walk) — bus ride ~5.0km.
        // → Route 22: less origin/dest walk (sum ~400m), shorter bus ride.
        // → Route 7: less walking sum (~107m), longer bus ride.
        // Actually wait — recompute: route 7 has both stops closer to origin/dest,
        // so route 7 has LESS walking but SAME bus distance roughly.
        // Set up explicitly:
        let stops: [BusStop] = [
            // Route 22: stops further from endpoints (~250m walks) but bus ride is shorter.
            BusStop(id: 100, route: "22", name: "22 Origin",
                    latitude: 41.8775, longitude: -87.700, directionLabel: "East"),
            BusStop(id: 101, route: "22", name: "22 Dest",
                    latitude: 41.8775, longitude: -87.640, directionLabel: "East"),
            // Route 7: stops on the doorstep (~30m walks) but bus runs a longer
            // alignment that adds distance.
            BusStop(id: 200, route: "7", name: "7 Origin",
                    latitude: 41.8803, longitude: -87.700, directionLabel: "East"),
            BusStop(id: 201, route: "7", name: "7 Dest",
                    latitude: 41.8803, longitude: -87.640, directionLabel: "East"),
        ]
        // Both routes have identical transit distance (same lat for their pairs),
        // so to introduce a tradeoff we tilt the destination off-axis.
        // Easier: swap by giving route 7 a longer bus ride via an out-of-line
        // alighting stop.
        let tradeoffStops: [BusStop] = [
            BusStop(id: 100, route: "22", name: "22 Origin",
                    latitude: 41.8775, longitude: -87.700, directionLabel: "East"),
            BusStop(id: 101, route: "22", name: "22 Dest",
                    latitude: 41.8775, longitude: -87.642, directionLabel: "East"),
            BusStop(id: 200, route: "7", name: "7 Origin (close)",
                    latitude: 41.8800, longitude: -87.7002, directionLabel: "East"),
            // Route 7's destination stop is 200m PAST the target along the bus
            // direction — adds ~200m to the bus ride compared to route 22.
            BusStop(id: 201, route: "7", name: "7 Dest (close to dest)",
                    latitude: 41.8800, longitude: -87.6378, directionLabel: "East"),
        ]
        _ = stops
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: [],
            busStops: tradeoffStops,
            metraStations: []
        )
        let busPlans = plans.filter { $0.flavor == .busShortestRide || $0.flavor == .busShortestWalk }
        #expect(busPlans.count == 2)
        // The shortestRide plan should have a smaller transit-leg distance
        // than the shortestWalk plan.
        let shortestRide = busPlans.first(where: { $0.flavor == .busShortestRide })
        let shortestWalk = busPlans.first(where: { $0.flavor == .busShortestWalk })
        let rideTransit = shortestRide?.legs.first(where: { $0.mode == .transit })?.distanceMeters ?? 0
        let walkTransit = shortestWalk?.legs.first(where: { $0.mode == .transit })?.distanceMeters ?? 0
        #expect(rideTransit < walkTransit)
        // And shortestWalk should have a smaller total walking distance.
        let rideWalks = (shortestRide?.legs.filter { $0.mode == .walking }.map(\.distanceMeters).reduce(0, +)) ?? 0
        let walkWalks = (shortestWalk?.legs.filter { $0.mode == .walking }.map(\.distanceMeters).reduce(0, +)) ?? 0
        #expect(walkWalks < rideWalks)
    }

    /// When the tradeoff picks land on the same route (no second-best on a
    /// different route), only the shortestRide one is surfaced — pinning
    /// either would write the same `pinnedBusRoute`.
    @Test func dedupesBusPlansWhenBothTradeoffsAreSameRoute() {
        let stops: [BusStop] = [
            BusStop(id: 100, route: "22", name: "Origin Stop",
                    latitude: 41.880, longitude: -87.701, directionLabel: "East"),
            BusStop(id: 101, route: "22", name: "Dest Stop",
                    latitude: 41.880, longitude: -87.642, directionLabel: "East"),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.700),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: [],
            busStops: stops,
            metraStations: []
        )
        let busPlans = plans.filter { $0.flavor == .busShortestRide || $0.flavor == .busShortestWalk }
        #expect(busPlans.count == 1)
        #expect(busPlans.first?.flavor == .busShortestRide)
    }

    /// Short trips (~500 m direct) shouldn't generate any transit plan; the
    /// user is better off walking.
    @Test func skipsPlanForVeryShortTrips() {
        let stations: [LStation] = [
            LStation(id: 1, name: "Origin Station", latitude: 41.880, longitude: -87.700,
                     servedLines: [.blue]),
            LStation(id: 2, name: "Dest Station", latitude: 41.880, longitude: -87.694,
                     servedLines: [.blue]),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.701),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.693),
            stations: stations,
            busStops: [],
            metraStations: []
        )
        #expect(plans.isEmpty)
    }

    /// Transit options whose nearest station is far past the walk cap should
    /// not appear in the plan.
    @Test func rejectsRoutesBeyondWalkCap() {
        let stations: [LStation] = [
            LStation(id: 1, name: "Far Origin", latitude: 41.900, longitude: -87.700,
                     servedLines: [.blue]), // ~2.2 km from origin
            LStation(id: 2, name: "Far Dest", latitude: 41.900, longitude: -87.650,
                     servedLines: [.blue]),
        ]
        let planner = LocalTransitPlanner(maxStationWalkMeters: 1_500)
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.880, longitude: -87.701),
            to: PlannerCoordinate(latitude: 41.880, longitude: -87.640),
            stations: stations,
            busStops: [],
            metraStations: []
        )
        #expect(plans.isEmpty)
    }

    @Test func producesMetraPlanWhenStationsBracketTheTrip() throws {
        let metraStations: [MetraStation] = [
            MetraStation(
                id: "origin",
                name: "Origin Metra",
                latitude: 41.880,
                longitude: -87.700,
                zoneId: nil,
                url: nil,
                servedRoutes: ["UP-W"]
            ),
            MetraStation(
                id: "dest",
                name: "Dest Metra",
                latitude: 41.880,
                longitude: -87.640,
                zoneId: nil,
                url: nil,
                servedRoutes: ["UP-W"]
            ),
        ]
        let planner = LocalTransitPlanner()
        let plans = planner.plan(
            from: PlannerCoordinate(latitude: 41.881, longitude: -87.701),
            to: PlannerCoordinate(latitude: 41.881, longitude: -87.639),
            stations: [],
            busStops: [],
            metraStations: metraStations
        )
        let metra = try #require(plans.first)
        #expect(metra.flavor == .metra)
        let resolution = metra.legs.first(where: { $0.mode == .transit })?.transit?.resolution
        #expect(resolution == .metra("UP-W"))
    }
}
