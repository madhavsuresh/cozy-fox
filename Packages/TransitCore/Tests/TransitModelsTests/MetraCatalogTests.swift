import Foundation
import Testing
import TransitModels

@Suite("MetraCatalog")
struct MetraCatalogTests {
    @Test func departureGroupsUseChicagoRelativeDirections() {
        let groups = MetraStationCatalog.departureGroups(
            routeId: "BNSF",
            stationId: "LAGRANGE",
            now: Self.morningCommute
        )
        let departures = groups.compactMap(\.nextDepartureAt)

        #expect(Set(groups.map(\.direction)) == Set([.toChicago, .fromChicago]))
        #expect(Set(groups.map(\.title)) == Set(["To Chicago", "From Chicago"]))
        #expect(groups.allSatisfy { !$0.departures.isEmpty && $0.departures.count <= 3 })
        #expect(departures == departures.sorted())
    }

    @Test func terminalArrivalsAreNotShownAsDepartures() {
        let chicagoUnionStationInbound = MetraScheduleCatalog.upcomingDepartures(
            stationId: "CUS",
            routeId: "BNSF",
            directionId: 1,
            now: Self.morningCommute,
            horizon: 24 * 60 * 60
        )
        let chicagoUnionStationGroups = MetraStationCatalog.departureGroups(
            routeId: "BNSF",
            stationId: "CUS",
            now: Self.morningCommute
        )

        #expect(chicagoUnionStationInbound.isEmpty)
        #expect(chicagoUnionStationGroups.map(\.direction) == [.fromChicago])
    }

    private static let morningCommute = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(identifier: "America/Chicago"),
        year: 2026,
        month: 5,
        day: 14,
        hour: 4
    ).date!
}
