import Foundation
import Testing
import TransitModels
@testable import CozyFox

@MainActor
@Suite("IntercampusTrafficETAResolver")
struct IntercampusTrafficETAResolverTests {
    // Real catalog stop IDs (Ward + Ryan Field serve both directions; Central/Jackson is southbound-only).
    private static let wardStopId = "6983f6d3-fcd9-4932-b9fb-7120f8c2f999"
    private static let ryanFieldStopId = "60e7b447-b29d-4812-bf93-7a77a1d5ae5b"
    private static let centralJacksonStopId = "b3f50cbe-621f-4664-934a-fe48d4901250"
    private static let northboundRouteId = "23174203-507c-48fe-811a-5d13fcf7be65"
    private static let southboundRouteId = "ebee9228-c993-4279-b7ce-8fca0a46ca65"

    // MARK: Fixtures

    private static func makeArrival(
        id: String = UUID().uuidString,
        tripId: String = UUID().uuidString,
        stopId: String,
        direction: IntercampusDirection,
        vehicleId: String? = nil,
        vehicleLocation: IntercampusVehicleLocation? = nil,
        timeSource: IntercampusArrivalTimeSource = .liveMap,
        arrivalAt: Date,
        generatedAt: Date
    ) -> IntercampusArrival {
        IntercampusArrival(
            id: id,
            routeId: direction == .northbound ? northboundRouteId : southboundRouteId,
            direction: direction,
            tripId: tripId,
            vehicleId: vehicleId,
            vehicleLabel: nil,
            stopId: stopId,
            stopName: "",
            destinationName: "",
            generatedAt: generatedAt,
            arrivalAt: arrivalAt,
            delaySeconds: nil,
            isDelayed: false,
            timeSource: timeSource,
            vehicleLocation: vehicleLocation
        )
    }

    private static func vehicleLocation(
        latitude: Double = 41.895,
        longitude: Double = -87.619,
        observedAt: Date,
        id: String? = nil
    ) -> IntercampusVehicleLocation {
        IntercampusVehicleLocation(
            id: id,
            label: nil,
            latitude: latitude,
            longitude: longitude,
            heading: nil,
            observedAt: observedAt
        )
    }

    private static let sampleEstimate = IntercampusTrafficETASample(
        travelTime: 240,
        distanceMeters: 1_200
    )

    // MARK: Candidate filtering

    @Test func leavesArrivalsAloneWhenVehicleLocationMissing() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher()
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            stopId: Self.wardStopId,
            direction: .northbound,
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        let result = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now
        )

        #expect(result == [arrival])
        #expect(await fetcher.callCount == 0)
    }

    @Test func skipsArrivalsWithStaleVehiclePosition() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleLocation: Self.vehicleLocation(observedAt: now.addingTimeInterval(-3 * 60 - 5)),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        let result = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now
        )

        #expect(result == [arrival])
        #expect(await fetcher.callCount == 0)
    }

    @Test func skipsArrivalsForStopsNotInCatalog() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            stopId: "not-a-real-stop-id",
            direction: .northbound,
            vehicleLocation: Self.vehicleLocation(observedAt: now),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        let result = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now
        )

        #expect(result == [arrival])
        #expect(await fetcher.callCount == 0)
    }

    @Test func skipsArrivalsAlreadyMarkedTraffic() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleLocation: Self.vehicleLocation(observedAt: now),
            timeSource: .traffic,
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now
        )

        #expect(await fetcher.callCount == 0)
    }

    @Test func dedupesArrivalsWithSameStopAndDirection() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let earlier = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )
        let later = Self.makeArrival(
            tripId: "trip-B",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-2",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-2"),
            arrivalAt: now.addingTimeInterval(900),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(
            to: [later, earlier],
            priorityStopIds: [],
            now: now
        )

        // Only the earlier arrival at (Ward, NB) gets a fetch.
        #expect(await fetcher.callCount == 1)
    }

    // MARK: Successful application

    @Test func appliesTrafficEstimateAndSwitchesTimeSource() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleLocation: Self.vehicleLocation(observedAt: now),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        let result = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now
        )

        #expect(result.first?.timeSource == .traffic)
        #expect(result.first?.arrivalAt == now.addingTimeInterval(240))
        #expect(result.first?.trafficEstimate?.travelTime == 240)
        #expect(result.first?.trafficEstimate?.distanceMeters == 1_200)
        #expect(result.first?.trafficEstimate?.sourceArrivalAt == now.addingTimeInterval(300))
        #expect(await fetcher.callCount == 1)
    }

    // MARK: Caching

    @Test func reusesCachedEstimateOnSubsequentCalls() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(to: [arrival], priorityStopIds: [], now: now)
        let second = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now.addingTimeInterval(30)
        )

        #expect(second.first?.timeSource == .traffic)
        #expect(await fetcher.callCount == 1)
    }

    @Test func cacheStaysWarmWhenBusMoves() async {
        // The fix: a moving bus should still hit the cache while the TTL is
        // valid. Previously the cache key bucketed lat/lon to ~11 m, so every
        // refresh missed the cache.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let firstArrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(
                latitude: 41.895,
                longitude: -87.619,
                observedAt: now,
                id: "bus-1"
            ),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )
        // 30s later, same bus + trip + stop, but the bus has moved a few hundred metres.
        let secondArrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(
                latitude: 41.900,
                longitude: -87.625,
                observedAt: now.addingTimeInterval(30),
                id: "bus-1"
            ),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(to: [firstArrival], priorityStopIds: [], now: now)
        _ = await resolver.applyingTrafficEstimates(
            to: [secondArrival],
            priorityStopIds: [],
            now: now.addingTimeInterval(30)
        )

        #expect(await fetcher.callCount == 1)
    }

    @Test func refetchesAfterCacheTTLExpires() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([
            .sample(Self.sampleEstimate),
            .sample(IntercampusTrafficETASample(travelTime: 200, distanceMeters: 1_100)),
        ])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let firstArrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )
        // 91s later — past the 90s success TTL.
        let later = now.addingTimeInterval(91)
        let laterArrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: later, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(to: [firstArrival], priorityStopIds: [], now: now)
        let result = await resolver.applyingTrafficEstimates(
            to: [laterArrival],
            priorityStopIds: [],
            now: later
        )

        #expect(await fetcher.callCount == 2)
        #expect(result.first?.trafficEstimate?.travelTime == 200)
    }

    @Test func cachesNegativeResultBriefly() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.noRoute])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(to: [arrival], priorityStopIds: [], now: now)
        // Within the 45s failure TTL — should not refetch.
        let nextArrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now.addingTimeInterval(30), id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )
        let result = await resolver.applyingTrafficEstimates(
            to: [nextArrival],
            priorityStopIds: [],
            now: now.addingTimeInterval(30)
        )

        #expect(result.first?.timeSource == .liveMap)
        #expect(result.first?.trafficEstimate == nil)
        #expect(await fetcher.callCount == 1)
    }

    @Test func cancellationIsNotCached() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([.throwing, .sample(Self.sampleEstimate)])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let arrival = Self.makeArrival(
            tripId: "trip-A",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "bus-1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "bus-1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        _ = await resolver.applyingTrafficEstimates(to: [arrival], priorityStopIds: [], now: now)
        // Immediately retry — cancellation must not poison the cache.
        let result = await resolver.applyingTrafficEstimates(
            to: [arrival],
            priorityStopIds: [],
            now: now.addingTimeInterval(1)
        )

        #expect(await fetcher.callCount == 2)
        #expect(result.first?.timeSource == .traffic)
    }

    // MARK: Budget + priority

    @Test func capsFreshFetchesAtBudget() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher(
            Array(repeating: .sample(Self.sampleEstimate), count: 10)
        )
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        // Five distinct (stop, direction) pairs, all within the position-age window.
        let arrivals = [
            Self.makeArrival(
                tripId: "t1",
                stopId: Self.wardStopId,
                direction: .northbound,
                vehicleId: "v1",
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v1"),
                arrivalAt: now.addingTimeInterval(120),
                generatedAt: now
            ),
            Self.makeArrival(
                tripId: "t2",
                stopId: Self.wardStopId,
                direction: .southbound,
                vehicleId: "v2",
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v2"),
                arrivalAt: now.addingTimeInterval(180),
                generatedAt: now
            ),
            Self.makeArrival(
                tripId: "t3",
                stopId: Self.ryanFieldStopId,
                direction: .northbound,
                vehicleId: "v3",
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v3"),
                arrivalAt: now.addingTimeInterval(240),
                generatedAt: now
            ),
            Self.makeArrival(
                tripId: "t4",
                stopId: Self.ryanFieldStopId,
                direction: .southbound,
                vehicleId: "v4",
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v4"),
                arrivalAt: now.addingTimeInterval(300),
                generatedAt: now
            ),
            Self.makeArrival(
                tripId: "t5",
                stopId: Self.centralJacksonStopId,
                direction: .southbound,
                vehicleId: "v5",
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v5"),
                arrivalAt: now.addingTimeInterval(360),
                generatedAt: now
            ),
        ]

        let result = await resolver.applyingTrafficEstimates(
            to: arrivals,
            priorityStopIds: [],
            now: now
        )

        #expect(await fetcher.callCount == 4)
        let adjusted = result.filter { $0.timeSource == .traffic }
        #expect(adjusted.count == 4)
    }

    @Test func priorityStopsAreFetchedFirstUnderBudget() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher(
            Array(repeating: .sample(Self.sampleEstimate), count: 10)
        )
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        // Priority stop arrives last by clock, but should still get a fetch.
        let priorityArrival = Self.makeArrival(
            id: "priority",
            tripId: "t-priority",
            stopId: Self.centralJacksonStopId,
            direction: .southbound,
            vehicleId: "vP",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "vP"),
            arrivalAt: now.addingTimeInterval(900),
            generatedAt: now
        )
        let earlierArrivals: [IntercampusArrival] = [
            (Self.wardStopId, IntercampusDirection.northbound, 120.0, "vA"),
            (Self.wardStopId, IntercampusDirection.southbound, 180.0, "vB"),
            (Self.ryanFieldStopId, IntercampusDirection.northbound, 240.0, "vC"),
            (Self.ryanFieldStopId, IntercampusDirection.southbound, 300.0, "vD"),
        ].enumerated().map { index, params in
            Self.makeArrival(
                id: "early-\(index)",
                tripId: "t-early-\(index)",
                stopId: params.0,
                direction: params.1,
                vehicleId: params.3,
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: params.3),
                arrivalAt: now.addingTimeInterval(params.2),
                generatedAt: now
            )
        }

        let result = await resolver.applyingTrafficEstimates(
            to: earlierArrivals + [priorityArrival],
            priorityStopIds: [Self.centralJacksonStopId],
            now: now
        )

        #expect(await fetcher.callCount == 4)
        let priority = result.first { $0.id == "priority" }
        #expect(priority?.timeSource == .traffic)
        // Exactly one of the four early arrivals lost the budget race.
        let adjustedEarly = result.filter { $0.id != "priority" && $0.timeSource == .traffic }
        #expect(adjustedEarly.count == 3)
    }

    @Test func cacheHitsDoNotConsumeBudget() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher(
            Array(repeating: .sample(Self.sampleEstimate), count: 10)
        )
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)

        // Warm the cache with one arrival.
        let warmer = Self.makeArrival(
            tripId: "t-warm",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "vW",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "vW"),
            arrivalAt: now.addingTimeInterval(120),
            generatedAt: now
        )
        _ = await resolver.applyingTrafficEstimates(to: [warmer], priorityStopIds: [], now: now)

        // Now fire a refresh with the warmed arrival plus 4 fresh ones.
        // Total candidates = 5, but the warmed one comes from cache, so all
        // 4 fresh fetches should still complete.
        let freshArrivals: [IntercampusArrival] = [
            (Self.wardStopId, IntercampusDirection.southbound, 180.0, "vB"),
            (Self.ryanFieldStopId, IntercampusDirection.northbound, 240.0, "vC"),
            (Self.ryanFieldStopId, IntercampusDirection.southbound, 300.0, "vD"),
            (Self.centralJacksonStopId, IntercampusDirection.southbound, 360.0, "vE"),
        ].enumerated().map { index, params in
            Self.makeArrival(
                id: "fresh-\(index)",
                tripId: "t-fresh-\(index)",
                stopId: params.0,
                direction: params.1,
                vehicleId: params.3,
                vehicleLocation: Self.vehicleLocation(observedAt: now, id: params.3),
                arrivalAt: now.addingTimeInterval(params.2),
                generatedAt: now
            )
        }

        let result = await resolver.applyingTrafficEstimates(
            to: freshArrivals + [warmer],
            priorityStopIds: [],
            now: now.addingTimeInterval(30)
        )

        // 1 fetch from warming + 4 fresh = 5 total.
        #expect(await fetcher.callCount == 5)
        let adjusted = result.filter { $0.timeSource == .traffic }
        #expect(adjusted.count == 5)
    }

    // MARK: Misc

    @Test func returnsEmptyForEmptyInput() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher()
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)

        let result = await resolver.applyingTrafficEstimates(
            to: [],
            priorityStopIds: [],
            now: now
        )

        #expect(result.isEmpty)
        #expect(await fetcher.callCount == 0)
    }

    @Test func resultIsSortedByAdjustedArrivalTime() async {
        // The faster traffic estimate moves a later TripShot ETA to the front.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeIntercampusTrafficFetcher([
            .sample(IntercampusTrafficETASample(travelTime: 60, distanceMeters: 500)),
        ])
        let resolver = IntercampusTrafficETAResolver(fetcher: fetcher)
        let earlierTripShot = Self.makeArrival(
            id: "early",
            tripId: "t-early",
            stopId: Self.ryanFieldStopId,
            direction: .northbound,
            arrivalAt: now.addingTimeInterval(180),
            generatedAt: now
        )
        let laterWithFastTraffic = Self.makeArrival(
            id: "late",
            tripId: "t-late",
            stopId: Self.wardStopId,
            direction: .northbound,
            vehicleId: "v1",
            vehicleLocation: Self.vehicleLocation(observedAt: now, id: "v1"),
            arrivalAt: now.addingTimeInterval(300),
            generatedAt: now
        )

        let result = await resolver.applyingTrafficEstimates(
            to: [earlierTripShot, laterWithFastTraffic],
            priorityStopIds: [],
            now: now
        )

        #expect(result.count == 2)
        #expect(result.first?.id == "late")
        #expect(result.last?.id == "early")
    }
}

// MARK: - Test fake

private actor FakeIntercampusTrafficFetcher: IntercampusTrafficETAFetching {
    enum Outcome: Sendable {
        case sample(IntercampusTrafficETASample)
        case noRoute
        case throwing
    }

    private(set) var callCount = 0
    private var queue: [Outcome]

    init(_ outcomes: [Outcome] = []) {
        self.queue = outcomes
    }

    func fetchEstimate(
        from origin: (latitude: Double, longitude: Double),
        to destination: (latitude: Double, longitude: Double),
        departingAt: Date
    ) async throws -> IntercampusTrafficETASample? {
        callCount += 1
        guard !queue.isEmpty else { return nil }
        switch queue.removeFirst() {
        case .sample(let sample): return sample
        case .noRoute: return nil
        case .throwing: throw CancellationError()
        }
    }
}
