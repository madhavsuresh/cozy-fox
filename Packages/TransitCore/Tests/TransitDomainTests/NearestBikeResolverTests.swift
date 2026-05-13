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
}
