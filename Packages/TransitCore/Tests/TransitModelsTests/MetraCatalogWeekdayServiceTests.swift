import Foundation
import Testing
import TransitModels

/// Regression: the catalog stores each service's weekday flags in
/// GTFS `calendar.txt` order (Mon=0…Sun=6). Before the fix, the
/// consumer was reading them in Apple `Calendar` order (Sun=0…Sat=6),
/// which silently swapped the Mon–Fri service onto Sun–Thu and the
/// Sat–Sun service onto Fri–Sat. The user-visible symptom: on Friday
/// the UP-N catalog returned the thinner weekend pattern (hourly
/// departures only) instead of the denser weekday pattern, hiding
/// the mid-hour trains.
///
/// The assertions below are deliberately structural — same-cohort
/// days must match, different cohorts must differ — so they survive
/// future GTFS publications without re-encoding specific clock
/// times. The specific morning-rush trains used to motivate the bug
/// report are *consequences* of the broader cohort mismatch, not the
/// invariant itself.
@Suite("MetraCatalog weekday → service")
struct MetraCatalogWeekdayServiceTests {

    @Test func fridayMatchesAnotherWeekday() {
        // Friday and Thursday should be in the same weekday cohort.
        // With the old indexing Thursday landed on the Mon–Fri
        // service while Friday landed on the weekend service — so
        // these two queries returned wildly different timetables on
        // the same line and station. Asserting equality catches that
        // exact bug without depending on any single train.
        let thursday = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 14)
        let friday   = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 15)
        #expect(!friday.isEmpty)
        #expect(friday == thursday)
    }

    @Test func fridayDiffersFromSaturday() {
        // Sanity check the other direction: weekday and weekend
        // cohorts have visibly different timetables. If the cohort
        // mapping ever collapsed Fri/Sat back together this would
        // notice.
        let friday   = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 15)
        let saturday = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 16)
        #expect(!friday.isEmpty)
        #expect(!saturday.isEmpty)
        #expect(friday != saturday)
    }

    @Test func weekdayCarriesMoreDeparturesThanWeekend() {
        // Density check: the weekday pattern is denser than either
        // weekend day in a fixed morning window. Before the fix,
        // Friday silently picked up the weekend service so it
        // matched (or undershot) Sat/Sun counts.
        let friday   = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 15)
        let saturday = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 16)
        let sunday   = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 17)
        #expect(friday.count > saturday.count)
        #expect(friday.count > sunday.count)
    }

    @Test func sundayDoesNotInheritWeekdayPattern() {
        // The inverse of the user-facing bug: with the old indexing,
        // Sunday was mapped onto the Mon–Fri service and so picked
        // up weekday-only trains. Sunday should look like a weekend
        // day, not like Thursday.
        let thursday = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 14)
        let sunday   = clockTimes(.uPN, .otc, year: 2026, month: 5, day: 17)
        #expect(!sunday.isEmpty)
        #expect(sunday != thursday)
    }

    // MARK: - Helpers

    private enum Route: String { case uPN = "UP-N" }
    private enum Station: String { case otc = "OTC" }

    /// Returns the set of HH:mm clock times (Chicago local) for UP-N
    /// outbound departures from OTC in the six-hour window starting
    /// at 09:00 on the given date.
    private func clockTimes(
        _ route: Route,
        _ station: Station,
        year: Int, month: Int, day: Int
    ) -> Set<String> {
        let now = Self.makeChicagoDate(year: year, month: month, day: day, hour: 9)
        let predictions = MetraScheduleCatalog.upcomingDepartures(
            stationId: station.rawValue,
            routeId: route.rawValue,
            directionId: 0,
            now: now,
            horizon: 6 * 60 * 60,
            limit: 64
        )
        return Set(predictions.map { Self.clockString(of: $0.scheduledAt) })
    }

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

    private static func clockString(of date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let chicagoTimeZone = TimeZone(identifier: "America/Chicago")!
    private static let chicagoCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = chicagoTimeZone
        return cal
    }()
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = chicagoTimeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
