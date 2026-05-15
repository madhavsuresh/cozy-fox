import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("Nearest bus stop resolver")
struct NearestBusStopResolverTests {
    @Test func returnsTwoNearestStopsPerDominantDirection() {
        let resolver = NearestBusStopResolver(maxDistanceMeters: 1_000)
        let origin = (lat: 41.0, lon: -87.0)
        let stops = resolver.nearestStopsPerDirection(
            onRoute: "22",
            to: origin,
            limitPerDirection: 2,
            catalog: [
                stop(id: 1, route: "22", name: "NB close", lat: 41.0001, direction: "Northbound"),
                stop(id: 2, route: "22", name: "NB next", lat: 41.0002, direction: "Northbound"),
                stop(id: 3, route: "22", name: "NB far", lat: 41.0010, direction: "Northbound"),
                stop(id: 4, route: "22", name: "SB close", lat: 40.9999, direction: "Southbound"),
                stop(id: 5, route: "22", name: "SB next", lat: 40.9998, direction: "Southbound"),
                stop(id: 6, route: "22", name: "SB far", lat: 40.9990, direction: "Southbound"),
            ]
        )

        let ids = stops.map(\.stop.id)
        #expect(ids.contains(1))
        #expect(ids.contains(2))
        #expect(ids.contains(4))
        #expect(ids.contains(5))
        #expect(!ids.contains(3))
        #expect(!ids.contains(6))
    }

    @Test func nearestDeduplicatesByRouteAndSortsByDistance() {
        let resolver = NearestBusStopResolver(maxDistanceMeters: 1_000)
        let origin = (lat: 41.0, lon: -87.0)
        let routes = resolver.nearest(
            to: origin,
            limit: 5,
            catalog: [
                stop(id: 1, route: "22", name: "22 close", lat: 41.0001, direction: "Northbound"),
                stop(id: 2, route: "22", name: "22 far",   lat: 41.0050, direction: "Northbound"),
                stop(id: 3, route: "36", name: "36 mid",   lat: 41.0005, direction: "Northbound"),
                stop(id: 4, route: "8",  name: "8 nearest",lat: 41.00005, direction: "Northbound"),
                stop(id: 5, route: "8",  name: "8 farther",lat: 41.0030, direction: "Northbound"),
                stop(id: 6, route: "147", name: "147 oor", lat: 41.0500, direction: "Northbound"),
            ]
        )

        #expect(routes.map(\.route) == ["8", "22", "36"])
        #expect(routes.map(\.id) == [4, 1, 3])
    }

    @Test func nearestPerDirectionStillReturnsOneStopEach() {
        let resolver = NearestBusStopResolver(maxDistanceMeters: 1_000)
        let origin = (lat: 41.0, lon: -87.0)
        let stops = resolver.nearestPerDirection(
            onRoute: "22",
            to: origin,
            catalog: [
                stop(id: 1, route: "22", name: "NB close", lat: 41.0001, direction: "Northbound"),
                stop(id: 2, route: "22", name: "NB next", lat: 41.0002, direction: "Northbound"),
                stop(id: 3, route: "22", name: "NB far", lat: 41.0010, direction: "Northbound"),
                stop(id: 4, route: "22", name: "SB close", lat: 40.9999, direction: "Southbound"),
                stop(id: 5, route: "22", name: "SB next", lat: 40.9998, direction: "Southbound"),
                stop(id: 6, route: "22", name: "SB far", lat: 40.9990, direction: "Southbound"),
            ]
        )

        #expect(stops.map(\.id).sorted() == [1, 4])
    }

    private func stop(
        id: Int,
        route: String,
        name: String,
        lat: Double,
        direction: String
    ) -> BusStop {
        BusStop(
            id: id,
            route: route,
            name: name,
            latitude: lat,
            longitude: -87.0,
            directionLabel: direction
        )
    }
}
