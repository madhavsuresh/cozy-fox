import Foundation
import Testing
import TransitModels

@Suite("MetraCatalog")
struct MetraCatalogTests {
    @Test func directionChoicesAreOrderedByNextDeparture() {
        let now = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "America/Chicago"),
            year: 2026,
            month: 5,
            day: 14,
            hour: 4
        ).date!

        let choices = MetraStationCatalog.directionChoices(
            routeId: "BNSF",
            stationId: "AURORA",
            now: now
        )
        let departures = choices.compactMap(\.nextDepartureAt)

        #expect(choices.count >= 2)
        #expect(departures.count == choices.count)
        #expect(departures == departures.sorted())
        #expect(choices.allSatisfy { choice in
            guard let nextDepartureAt = choice.nextDepartureAt else { return false }
            return choice.label.contains(MetraDepartureFormatter.timeString(nextDepartureAt))
        })
    }
}
