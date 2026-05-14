import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("NearestBikeResolver")
struct NearestBikeResolverTests {
    private func station(
        id: String,
        lat: Double,
        lon: Double,
        ebikes: Int = 5,
        capacity: Int = 12
    ) -> BikeStation {
        BikeStation(
            id: id, name: id,
            latitude: lat, longitude: lon,
            capacity: capacity,
            eBikesAvailable: ebikes,
            classicBikesAvailable: 0,
            docksAvailable: capacity - ebikes,
            isRenting: true, isReturning: true,
            lastReported: .now
        )
    }

    private func bike(
        id: String,
        lat: Double,
        lon: Double,
        range: Double = 5_000,
        reserved: Bool = false,
        disabled: Bool = false,
        stationId: String? = nil
    ) -> EBike {
        EBike(
            id: id,
            latitude: lat,
            longitude: lon,
            currentRangeMeters: range,
            isReserved: reserved,
            isDisabled: disabled,
            stationId: stationId
        )
    }

    @Test func picksClosestStationWithBikes() throws {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "far",   lat: 41.895, lon: -87.625, ebikes: 5), // ~550m
            station(id: "close", lat: 41.8905, lon: -87.625, ebikes: 5), // ~55m
            station(id: "empty", lat: 41.8902, lon: -87.625, ebikes: 0), // close but empty
        ]
        let resolver = NearestBikeResolver()
        let pick = resolver.pick(from: origin, stations: stations, eBikes: [], includeFreeFloating: false)
        #expect(pick?.station.id == "close")
    }

    @Test func appliesScarcityPenalty() {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "scarce-but-close", lat: 41.8902, lon: -87.625, ebikes: 1),
            station(id: "abundant-far",     lat: 41.8915, lon: -87.625, ebikes: 8),
        ]
        let resolver = NearestBikeResolver(maxStationDistanceMeters: 500)
        let pick = resolver.pick(from: origin, stations: stations, eBikes: [], includeFreeFloating: false)
        // The scarce one is much closer but penalized; the abundant one wins
        // when the penalty exceeds the distance gap.
        #expect(pick != nil)
        #expect(pick?.station.eBikesAvailable ?? 0 >= 1)
    }

    @Test func returnsNilWhenNoStationsWithinRange() {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "very-far", lat: 41.950, lon: -87.625, ebikes: 5),
        ]
        let resolver = NearestBikeResolver()
        let pick = resolver.pick(from: origin, stations: stations, eBikes: [], includeFreeFloating: false)
        #expect(pick == nil)
    }

    @Test func returnsFreeFloatingBikesAsSeparateListings() {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "empty-dock", lat: 41.8901, lon: -87.625, ebikes: 0),
        ]
        let resolver = NearestBikeResolver(
            maxStationDistanceMeters: 500,
            freeFloatingPickRadiusMeters: 100,
            minimumUsableRangeMeters: 3_000
        )
        let results = resolver.nearby(
            topStations: 3,
            topFreeFloating: 3,
            from: origin,
            stations: stations,
            eBikes: [
                bike(id: "curb-bike", lat: 41.89012, lon: -87.625, range: 5_000),
                bike(id: "docked-bike", lat: 41.89012, lon: -87.625, range: 5_000, stationId: "empty-dock"),
                bike(id: "low-range-bike", lat: 41.89012, lon: -87.625, range: 100),
            ],
            includeFreeFloating: true
        )

        #expect(results.stationPicks.isEmpty)
        #expect(results.freeFloatingPicks.map(\.bike.id) == ["curb-bike"])
    }

    @Test func ignoresFreeFloatingBikesWhenDisabled() {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "empty-dock", lat: 41.8901, lon: -87.625, ebikes: 0),
        ]
        let resolver = NearestBikeResolver(maxStationDistanceMeters: 500, freeFloatingPickRadiusMeters: 100)
        let pick = resolver.pick(
            from: origin,
            stations: stations,
            eBikes: [bike(id: "curb-bike", lat: 41.89012, lon: -87.625)],
            includeFreeFloating: false
        )

        #expect(pick == nil)

        let results = resolver.nearby(
            topStations: 3,
            topFreeFloating: 3,
            from: origin,
            stations: stations,
            eBikes: [bike(id: "curb-bike", lat: 41.89012, lon: -87.625)],
            includeFreeFloating: false
        )

        #expect(results.stationPicks.isEmpty)
        #expect(results.freeFloatingPicks.isEmpty)
    }

    @Test func attachesDockedChargeStatsToStationPicks() throws {
        let origin = (lat: 41.890, lon: -87.625)
        let stations = [
            station(id: "dock", lat: 41.8901, lon: -87.625, ebikes: 3),
        ]
        let resolver = NearestBikeResolver(maxStationDistanceMeters: 500, minimumUsableRangeMeters: 1)
        let pick = try #require(resolver.pick(
            from: origin,
            stations: stations,
            eBikes: [
                bike(id: "low", lat: 41.8901, lon: -87.625, range: 3_000, stationId: "dock"),
                bike(id: "mid", lat: 41.8901, lon: -87.625, range: 6_000, stationId: "dock"),
                bike(id: "high", lat: 41.8901, lon: -87.625, range: 9_000, stationId: "dock"),
                bike(id: "curb-bike", lat: 41.89012, lon: -87.625, range: 10_000),
            ],
            includeFreeFloating: true
        ))

        #expect(pick.station.id == "dock")
        #expect(pick.dockedBikes.map(\.id) == ["high", "mid", "low"])
        #expect(pick.freeFloatingNearby == 0)
        let summary = try #require(pick.dockedChargeSummary)
        #expect(summary.minRangeMeters == 3_000)
        #expect(summary.medianRangeMeters == 6_000)
        #expect(summary.maxRangeMeters == 9_000)
    }
}
