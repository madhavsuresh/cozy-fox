import Foundation
import Testing
import TransitModels

/// Regression: the catalog stores each service's weekday flags in
/// GTFS `calendar.txt` order (Mon=0…Sun=6). Before the fix, the
/// consumer was reading them in Apple `Calendar` order (Sun=0…Sat=6),
/// which silently swapped the Mon–Fri service onto Sun–Thu and the
/// Sat–Sun service onto Fri–Sat. The visible symptom: on Friday
/// the UP-N catalog hid the standard weekday departures (the trains
/// at 09:32 and 10:02 outbound from OTC) and instead returned the
/// thinner Sat/Sun pattern.
@Suite("MetraCatalog weekday → service")
struct MetraCatalogWeekdayServiceTests {

    @Test func fridayUpNHasWeekdayMorningDepartures() {
        // Friday 2026-05-15 at 09:00 Chicago.
        let nowFriday = Self.makeChicagoDate(year: 2026, month: 5, day: 15, hour: 9)
        let outbound = MetraScheduleCatalog.upcomingDepartures(
            stationId: "OTC",
            routeId: "UP-N",
            directionId: 0,
            now: nowFriday,
            horizon: 6 * 60 * 60,
            limit: 16
        )
        let times = outbound.map { Self.localClock(of: $0.scheduledAt) }
        // The canonical weekday pattern includes 09:32 → Waukegan and
        // 10:02 → Kenosha. If we ever fall back onto the weekend
        // service those two departures disappear (the weekend pattern
        // only carries the hourly :32 trains).
        #expect(times.contains("09:32"))
        #expect(times.contains("10:02"))
    }

    @Test func sundayUpNHasNoWeekdayOnlyDepartures() {
        // Sunday 2026-05-17 at 09:00 Chicago. The 10:02 departure is
        // weekday-only — surfacing it on Sunday would mean we were
        // still confusing service IDs after the fix.
        let nowSunday = Self.makeChicagoDate(year: 2026, month: 5, day: 17, hour: 9)
        let outbound = MetraScheduleCatalog.upcomingDepartures(
            stationId: "OTC",
            routeId: "UP-N",
            directionId: 0,
            now: nowSunday,
            horizon: 6 * 60 * 60,
            limit: 16
        )
        let times = outbound.map { Self.localClock(of: $0.scheduledAt) }
        #expect(!times.contains("10:02"))
        // Sunday morning still has trains — sanity check we didn't
        // simply turn the catalog off.
        #expect(!outbound.isEmpty)
    }

    @Test func saturdayAndSundayDepartureCountIsLowerThanWeekday() {
        // Same hour-of-day window across three days during the
        // 2026-05-04..2026-06-07 service period. The weekday pattern
        // is noticeably denser than either weekend day. If the
        // weekday/weekend indices were swapped we'd see Friday
        // matching Sat/Sun.
        func count(year: Int, month: Int, day: Int) -> Int {
            let now = Self.makeChicagoDate(year: year, month: month, day: day, hour: 9)
            return MetraScheduleCatalog.upcomingDepartures(
                stationId: "OTC",
                routeId: "UP-N",
                directionId: 0,
                now: now,
                horizon: 6 * 60 * 60,
                limit: 32
            ).count
        }
        let friday = count(year: 2026, month: 5, day: 15)
        let saturday = count(year: 2026, month: 5, day: 16)
        let sunday = count(year: 2026, month: 5, day: 17)
        #expect(friday > saturday)
        #expect(friday > sunday)
    }

    // MARK: - Helpers

    private static func makeChicagoDate(
        year: Int, month: Int, day: Int, hour: Int
    ) -> Date {
        var components = DateComponents()
        components.calendar = chicagoCalendar
        components.timeZone = chicagoTimeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        return components.date!
    }

    private static func localClock(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = chicagoTimeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static let chicagoTimeZone = TimeZone(identifier: "America/Chicago")!
    private static let chicagoCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicagoTimeZone
        return cal
    }()
}
