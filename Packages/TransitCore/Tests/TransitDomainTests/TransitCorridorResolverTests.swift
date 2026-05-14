import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("TransitCorridorResolver")
struct TransitCorridorResolverTests {
    @Test func returnsBusCoverageByLocalCorridor() {
        let resolver = TransitCorridorResolver(localRouteRadiusMeters: 1_000)
        let origin = (lat: 41.0, lon: -87.0)
        let picks = resolver.nearbyBusCandidates(
            to: origin,
            radiusMeters: 1_000,
            limitPerCorridor: 1,
            catalog: [
                stop(id: 1, route: "22", lat: 40.997, lon: -87.0, direction: "Southbound"),
                stop(id: 2, route: "22", lat: 41.003, lon: -87.0, direction: "Northbound"),
                stop(id: 3, route: "66", lat: 41.0, lon: -87.003, direction: "Westbound"),
                stop(id: 4, route: "66", lat: 41.0, lon: -86.997, direction: "Eastbound"),
                stop(id: 5, route: "56", lat: 40.997, lon: -87.003, direction: "Southbound"),
                stop(id: 6, route: "56", lat: 41.003, lon: -86.997, direction: "Northbound"),
            ]
        )

        #expect(picks.map(\.corridor) == [.northSouth, .eastWest, .diagonal])
        #expect(Set(picks.map(\.stop.route)) == ["22", "66", "56"])
    }

    @Test func returnsTrainCoverageByLocalCorridor() {
        let resolver = TransitCorridorResolver(localRouteRadiusMeters: 1_000)
        let origin = (lat: 41.0, lon: -87.0)
        let picks = resolver.nearbyTrainCandidates(
            to: origin,
            radiusMeters: 1_000,
            limitPerCorridor: 1,
            catalog: [
                station(id: 1, name: "Red South", lat: 40.997, lon: -87.0, lines: [.red]),
                station(id: 2, name: "Red North", lat: 41.003, lon: -87.0, lines: [.red]),
                station(id: 3, name: "Green West", lat: 41.0, lon: -87.003, lines: [.green]),
                station(id: 4, name: "Green East", lat: 41.0, lon: -86.997, lines: [.green]),
                station(id: 5, name: "Blue South", lat: 40.997, lon: -87.003, lines: [.blue]),
                station(id: 6, name: "Blue North", lat: 41.003, lon: -86.997, lines: [.blue]),
            ]
        )

        #expect(picks.map(\.corridor) == [.northSouth, .eastWest, .diagonal])
        #expect(Set(picks.map(\.line)) == [.red, .green, .blue])
    }

    @Test func loopLinesAtLoopStationsUseLoopCorridor() {
        let resolver = TransitCorridorResolver()
        let clarkLake = station(
            id: 10,
            name: "Clark/Lake",
            lat: 41.8857,
            lon: -87.6309,
            lines: [.brown, .green]
        )

        #expect(resolver.trainCorridor(for: .brown, near: clarkLake, catalog: [clarkLake]) == .loop)
        #expect(resolver.trainCorridor(for: .green, near: clarkLake, catalog: [clarkLake]) != .loop)
    }

    private func stop(
        id: Int,
        route: String,
        lat: Double,
        lon: Double,
        direction: String
    ) -> BusStop {
        BusStop(
            id: id,
            route: route,
            name: "Stop \(id)",
            latitude: lat,
            longitude: lon,
            directionLabel: direction
        )
    }

    private func station(
        id: Int,
        name: String,
        lat: Double,
        lon: Double,
        lines: [LineColor]
    ) -> LStation {
        LStation(
            id: id,
            name: name,
            latitude: lat,
            longitude: lon,
            servedLines: lines
        )
    }
}
