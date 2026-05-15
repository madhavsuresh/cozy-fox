import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("HomewardSuggester")
struct HomewardSuggesterTests {
    private static var chicagoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        chicagoCalendar.date(from: DateComponents(
            calendar: chicagoCalendar,
            timeZone: chicagoCalendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private let suggester = HomewardSuggester()
    private let home = CommuteAnchors.Anchor(latitude: 41.965, longitude: -87.69, label: "Home")
    private let work = CommuteAnchors.Anchor(latitude: 41.882, longitude: -87.62, label: "Work")

    private func anchors(home: CommuteAnchors.Anchor? = nil, work: CommuteAnchors.Anchor? = nil) -> CommuteAnchors {
        CommuteAnchors(home: home, work: work)
    }

    /// 6 PM on a weekday (Mon May 11 2026, hour 18 — well past 17).
    private static let weekdayEvening = date(year: 2026, month: 5, day: 11, hour: 18)

    // MARK: - Happy path

    @Test func surfacesWhenAllGatesPass() {
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(home: home, work: work),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == true)
    }

    // MARK: - Gates

    @Test func suppressesWhenNoHomeAnchor() {
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(work: work),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func suppressesAtHome() {
        let result = suggester.shouldSurface(
            context: .atHome,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func suppressesAtWork() {
        let result = suggester.shouldSurface(
            context: .atWork,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func suppressesWithoutElsewhereTimestamp() {
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: nil,
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func suppressesShortOuting() {
        // Out for only 10 min — under the 30-min default.
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-10 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func suppressesEarlyAfternoon() {
        // 2 PM — before the 5 PM evening threshold AND no typical
        // back-home window in the empty profile.
        let twoPm = Self.date(year: 2026, month: 5, day: 11, hour: 14)
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: twoPm.addingTimeInterval(-60 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: twoPm,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func surfacesEarlyAfternoonWhenInTypicalBackHomeWindow() {
        // 2 PM. Profile has a typical "exitedWork → toHome" peak at
        // weekday 2 (Monday), hour 14. The window-match gate fires
        // even though we're below the evening hour threshold.
        let twoPm = Self.date(year: 2026, month: 5, day: 11, hour: 14)
        var summary = MobilityProfileSummary.empty
        let key = MobilityProfileSummary.departureKey(source: .exitedWork, direction: .toHome)
        var window = MobilityProfileSummary.DepartureWindow()
        // Seed 3 samples at (Monday, 14) so matchesWindow with default
        // hourWindow=2, minSamples=2 succeeds.
        window.weekdayHourCounts[MobilityProfileSummary.DepartureWindow.key(weekday: 2, hour: 14)] = 3
        window.totalCount = 3
        summary.departureWindows[key] = window

        let profile = MobilityProfile(summary: summary)
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: twoPm.addingTimeInterval(-60 * 60),
            anchors: anchors(home: home),
            profile: profile,
            now: twoPm,
            calendar: Self.chicagoCalendar
        )
        #expect(result == true)
    }

    @Test func suppressesWhenSuppressedUntilInFuture() {
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            suppressedUntil: Self.weekdayEvening.addingTimeInterval(60 * 60),
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func surfacesAfterSuppressionExpires() {
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-90 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            suppressedUntil: Self.weekdayEvening.addingTimeInterval(-60),  // 1 min ago
            calendar: Self.chicagoCalendar
        )
        #expect(result == true)
    }

    // MARK: - Custom thresholds

    @Test func customDurationGate() {
        // 60-min duration gate, only out 45 min → suppressed.
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: Self.weekdayEvening.addingTimeInterval(-45 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: Self.weekdayEvening,
            minimumElsewhereDurationMinutes: 60,
            calendar: Self.chicagoCalendar
        )
        #expect(result == false)
    }

    @Test func customEveningThresholdShiftsTheBoundary() {
        // 3 PM — within an 8 AM evening threshold? Yes. Surface.
        let threePm = Self.date(year: 2026, month: 5, day: 11, hour: 15)
        let result = suggester.shouldSurface(
            context: .elsewhere,
            elsewhereSince: threePm.addingTimeInterval(-60 * 60),
            anchors: anchors(home: home),
            profile: .empty,
            now: threePm,
            eveningHourThreshold: 8,
            calendar: Self.chicagoCalendar
        )
        #expect(result == true)
    }
}
