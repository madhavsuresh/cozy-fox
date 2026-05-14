import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("Pinned line direction defaults")
struct PinnedLineDefaultResolverTests {
    @Test func trainUsesTrackedPreferenceForCurrentContext() {
        let resolver = PinnedLineDefaultResolver(clock: FakeClock(now(hour: 8)))
        let prefs = UserRoutePreferences(trains: [
            TrainPreference(
                mapId: 1,
                stopId: nil,
                stationName: "Home",
                line: .brown,
                directionLabel: "Loop",
                direction: .toWork
            ),
            TrainPreference(
                mapId: 2,
                stopId: nil,
                stationName: "Work",
                line: .brown,
                directionLabel: "Kimball",
                direction: .toHome
            ),
        ])

        let choice = resolver.preferredTrainDestination(
            line: .brown,
            availableDestinations: ["Kimball", "Loop"],
            preferences: prefs,
            profile: .empty,
            context: .atHome,
            location: location
        )

        #expect(choice == "Loop")
    }

    @Test func busUsesMostCommonHistoryNearCurrentLocation() {
        let clock = FakeClock(now(hour: 17))
        let resolver = PinnedLineDefaultResolver(clock: clock)
        var profile = MobilityProfile.empty
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: nil,
            stationId: nil,
            busRoute: "22",
            busDirection: "Southbound",
            origin: MobilityProfile.RouteLocation.bucketed(latitude: 41.88, longitude: -87.63),
            at: now(hour: 17).addingTimeInterval(-86_400),
            calendar: clock.calendar
        )
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: nil,
            stationId: nil,
            busRoute: "22",
            busDirection: "Southbound",
            origin: MobilityProfile.RouteLocation.bucketed(latitude: 41.88, longitude: -87.63),
            at: now(hour: 17).addingTimeInterval(-2 * 86_400),
            calendar: clock.calendar
        )
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: nil,
            stationId: nil,
            busRoute: "22",
            busDirection: "Northbound",
            origin: MobilityProfile.RouteLocation.bucketed(latitude: 41.88, longitude: -87.63),
            at: now(hour: 17).addingTimeInterval(-3 * 86_400),
            calendar: clock.calendar
        )

        let choice = resolver.preferredBusDirection(
            route: "22",
            availableDirections: ["Northbound", "Southbound"],
            preferences: .empty,
            profile: profile,
            context: .atWork,
            location: location
        )

        #expect(choice == "Southbound")
    }

    @Test func unavailableHistoryFallsBackToFirstAvailableDirection() {
        let resolver = PinnedLineDefaultResolver(clock: FakeClock(now(hour: 17)))
        let prefs = UserRoutePreferences(buses: [
            BusPreference(
                route: "66",
                stopId: 1,
                stopName: "Old",
                directionLabel: "Eastbound",
                direction: .toHome
            ),
        ])

        let choice = resolver.preferredBusDirection(
            route: "66",
            availableDirections: ["Westbound"],
            preferences: prefs,
            profile: .empty,
            context: .atWork,
            location: location
        )

        #expect(choice == "Westbound")
    }

    @Test func noHistoryFallsBackToFirstAvailableTrainDestination() {
        let resolver = PinnedLineDefaultResolver(clock: FakeClock(now(hour: 17)))

        let choice = resolver.preferredTrainDestination(
            line: .red,
            availableDestinations: ["Howard", "95th/Dan Ryan"],
            preferences: .empty,
            profile: .empty,
            context: .elsewhere,
            location: location
        )

        #expect(choice == "Howard")
    }

    private var location: LastKnownLocation {
        LastKnownLocation(
            latitude: 41.88,
            longitude: -87.63,
            recordedAt: now(hour: 17),
            source: .foreground
        )
    }

    private func now(hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 13,
            hour: hour
        ))!
    }
}
