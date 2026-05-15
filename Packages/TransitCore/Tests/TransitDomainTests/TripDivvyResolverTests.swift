import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("Trip Divvy resolver")
struct TripDivvyResolverTests {
    private func station(
        id: String,
        lat: Double,
        lon: Double,
        ebikes: Int = 0,
        docks: Int = 0,
        renting: Bool = true,
        returning: Bool = true
    ) -> BikeStation {
        BikeStation(
            id: id,
            name: id,
            latitude: lat,
            longitude: lon,
            capacity: ebikes + docks,
            eBikesAvailable: ebikes,
            classicBikesAvailable: 0,
            docksAvailable: docks,
            isRenting: renting,
            isReturning: returning,
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

    @Test func originStationsRequireRentableEBikesInsideRadius() {
        let origin = (lat: 41.8800, lon: -87.6300)
        let resolver = TripDivvyResolver(radiusMeters: 400)
        let picks = resolver.originStations(near: origin, stations: [
            station(id: "close", lat: 41.8805, lon: -87.6300, ebikes: 1),
            station(id: "second", lat: 41.8810, lon: -87.6300, ebikes: 4),
            station(id: "empty", lat: 41.8801, lon: -87.6300, ebikes: 0),
            station(id: "not-renting", lat: 41.8802, lon: -87.6300, ebikes: 3, renting: false),
            station(id: "far", lat: 41.8845, lon: -87.6300, ebikes: 8),
        ])

        #expect(picks.map(\.station.id) == ["close", "second"])
    }

    @Test func destinationStationsRequireReturnableOpenDocksInsideRadius() {
        let destination = (lat: 41.8800, lon: -87.6300)
        let resolver = TripDivvyResolver(radiusMeters: 400)
        let picks = resolver.destinationDockStations(near: destination, stations: [
            station(id: "close-dock", lat: 41.8805, lon: -87.6300, docks: 1),
            station(id: "second-dock", lat: 41.8810, lon: -87.6300, docks: 5),
            station(id: "full", lat: 41.8801, lon: -87.6300, docks: 0),
            station(id: "not-returning", lat: 41.8802, lon: -87.6300, docks: 3, returning: false),
            station(id: "far", lat: 41.8845, lon: -87.6300, docks: 8),
        ])

        #expect(picks.map(\.station.id) == ["close-dock", "second-dock"])
    }

    @Test func countsUsableFreeFloatingBikesInsideRadius() {
        let origin = (lat: 41.8800, lon: -87.6300)
        let resolver = TripDivvyResolver(radiusMeters: 400, minimumUsableRangeMeters: 3_000)
        let eBikes = [
            bike(id: "curb-a", lat: 41.8802, lon: -87.6300),
            bike(id: "curb-b", lat: 41.8804, lon: -87.6300),
            bike(id: "docked", lat: 41.8802, lon: -87.6300, stationId: "station"),
            bike(id: "low-range", lat: 41.8802, lon: -87.6300, range: 2_000),
            bike(id: "reserved", lat: 41.8802, lon: -87.6300, reserved: true),
            bike(id: "disabled", lat: 41.8802, lon: -87.6300, disabled: true),
            bike(id: "far", lat: 41.8845, lon: -87.6300),
        ]

        #expect(resolver.freeFloatingEBikeCount(
            near: origin,
            eBikes: eBikes,
            includeFreeFloating: true
        ) == 2)
        #expect(resolver.freeFloatingEBikeCount(
            near: origin,
            eBikes: eBikes,
            includeFreeFloating: false
        ) == 0)
    }
}
