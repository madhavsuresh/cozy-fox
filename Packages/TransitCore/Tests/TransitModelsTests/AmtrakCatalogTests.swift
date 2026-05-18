import Foundation
import Testing
@testable import TransitModels

@Suite("Amtrak catalog")
struct AmtrakCatalogTests {
    @Test func loadsRoutesStationsAndFeedMetadata() throws {
        let route = try #require(AmtrakStationCatalog.route(id: "51"))
        #expect(route.displayName == "Southwest Chief")
        #expect(route.kind == .rail)

        let station = try #require(AmtrakStationCatalog.station(id: "ABQ"))
        #expect(station.name.contains("Albuquerque"))
        #expect(station.timeZoneIdentifier == "America/Denver")
        #expect(station.servedRoutes.contains("51"))

        let routeStations = AmtrakStationCatalog.stations(onRoute: "51")
        #expect(routeStations.contains { $0.id == "ABQ" })
        #expect(AmtrakStationCatalog.feedInfo.publisherName.lowercased().contains("amtrak"))
    }

    @Test func upcomingDeparturesUseScheduleSource() {
        let now = Self.makeDate(
            timeZone: Self.denverTimeZone,
            year: 2026,
            month: 5,
            day: 30,
            hour: 13,
            minute: 0
        )

        let departures = AmtrakScheduleCatalog.upcomingDepartures(
            stationId: "ABQ",
            routeId: "51",
            directionId: 1,
            now: now,
            horizon: 2 * 60 * 60,
            limit: 8
        )

        #expect(!departures.isEmpty)
        #expect(departures.allSatisfy { $0.sourceLabel == "Schedule" })
        #expect(departures.allSatisfy { $0.isScheduled })
        #expect(departures.allSatisfy { !$0.isDelayed && !$0.isCanceled })
    }

    @Test func gtfsTimesPastMidnightStayOnServiceDateOffset() throws {
        let now = Self.makeDate(
            timeZone: Self.denverTimeZone,
            year: 2026,
            month: 5,
            day: 30,
            hour: 13,
            minute: 0
        )

        let train4 = try #require(
            AmtrakScheduleCatalog.upcomingDepartures(
                stationId: "ABQ",
                routeId: "51",
                directionId: 1,
                now: now,
                horizon: 2 * 60 * 60,
                limit: 8
            )
            .first { $0.trainNumber == "4" && $0.destinationName == "Chicago" }
        )

        #expect(Self.clockString(train4.scheduledAt, timeZone: Self.denverTimeZone) == "2026-05-30 13:31")
    }

    @Test func directionLookupUsesStopOrder() {
        let direction = AmtrakStationCatalog.directionId(
            routeId: "51",
            boardingStationId: "ABQ",
            targetStationId: "CHI"
        )

        #expect(direction == 1)
    }

    @Test func calendarDateAdditionActivatesExceptionOnlyService() {
        let store = Self.fixtureStore(
            weekdays: [false, false, false, false, false, false, false],
            exceptions: [
                AmtrakServiceException(serviceId: "svc", date: "20260518", type: 1)
            ]
        )
        let now = Self.makeDate(
            timeZone: Self.chicagoTimeZone,
            year: 2026,
            month: 5,
            day: 18,
            hour: 8,
            minute: 30
        )

        let departures = store.upcomingDepartures(
            stationId: "TST",
            routeId: "R",
            directionId: nil,
            destinationName: nil,
            now: now,
            horizon: 2 * 60 * 60,
            limit: 4
        )

        #expect(departures.count == 1)
        #expect(departures.first?.trainNumber == "900")
    }

    @Test func calendarDateRemovalSuppressesNormallyActiveService() {
        let store = Self.fixtureStore(
            weekdays: [true, true, true, true, true, true, true],
            exceptions: [
                AmtrakServiceException(serviceId: "svc", date: "20260518", type: 2)
            ]
        )
        let now = Self.makeDate(
            timeZone: Self.chicagoTimeZone,
            year: 2026,
            month: 5,
            day: 18,
            hour: 8,
            minute: 30
        )

        let departures = store.upcomingDepartures(
            stationId: "TST",
            routeId: "R",
            directionId: nil,
            destinationName: nil,
            now: now,
            horizon: 2 * 60 * 60,
            limit: 4
        )

        #expect(departures.isEmpty)
    }

    @Test func preferencesDecodeOlderPayloadWithEmptyAmtrakDefaults() throws {
        let data = Data("""
        {
          "trains": [],
          "buses": [],
          "metra": [],
          "includeFreeFloatingBikes": true,
          "hiddenModes": [],
          "hiddenTrainLines": [],
          "hiddenBusRoutes": [],
          "hiddenMetraRoutes": []
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)

        #expect(decoded.amtrak.isEmpty)
        #expect(decoded.hiddenAmtrakRoutes.isEmpty)
        #expect(decoded.pinnedAmtrakRoute == nil)
        #expect(decoded.isAmtrakRouteVisible("51"))
    }

    @Test func amtrakVisibilityHonorsModeAndRouteHides() {
        var prefs = UserRoutePreferences(pinnedAmtrakRoute: "51")
        prefs.hiddenAmtrakRoutes = ["51"]

        #expect(!prefs.isAmtrakRouteVisible("51"))
        #expect(prefs.pinnedAmtrakRoute == "51")

        prefs.hiddenAmtrakRoutes = []
        prefs.hiddenModes.insert(.amtrak)

        #expect(!prefs.isAmtrakRouteVisible("51"))
        #expect(prefs.pinnedAmtrakRoute == "51")
    }

    private static func makeDate(
        timeZone: TimeZone,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }

    private static func clockString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func fixtureStore(
        weekdays: [Bool],
        exceptions: [AmtrakServiceException]
    ) -> AmtrakCatalogStore {
        AmtrakCatalogStore(
            routes: [
                AmtrakRoute(
                    id: "R",
                    shortName: "R",
                    longName: "Fixture Route",
                    kind: .rail,
                    url: nil,
                    colorHex: "005DAA",
                    textColorHex: "FFFFFF"
                )
            ],
            stations: [
                AmtrakStation(
                    id: "TST",
                    name: "Fixture Station",
                    url: nil,
                    timeZoneIdentifier: "America/Chicago",
                    latitude: 41.0,
                    longitude: -87.0,
                    servedRoutes: ["R"]
                )
            ],
            services: [
                AmtrakService(
                    id: "svc",
                    weekdays: weekdays,
                    startDate: "20260518",
                    endDate: "20260518"
                )
            ],
            exceptions: exceptions,
            schedule: [
                AmtrakScheduleEntry(
                    routeId: "R",
                    serviceId: "svc",
                    tripId: "trip",
                    trainNumber: "900",
                    headsign: "Terminal",
                    directionId: 0,
                    stopId: "TST",
                    arrivalSeconds: 9 * 60 * 60,
                    departureSeconds: 9 * 60 * 60,
                    stopSequence: 1
                )
            ],
            feedInfo: AmtrakFeedInfo(
                publisherName: "Amtrak",
                publisherURL: nil,
                version: nil,
                startDate: "20260518",
                endDate: "20260518"
            )
        )
    }

    private static let denverTimeZone = TimeZone(identifier: "America/Denver")!
    private static let chicagoTimeZone = TimeZone(identifier: "America/Chicago")!
}
