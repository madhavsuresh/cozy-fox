import Foundation
import Testing
@testable import TransitModels

@Suite("HourClass / WeekdayClass / Season bucketing")
struct HourClassBucketingTests {
    @Test func hourClassBoundaries() {
        #expect(HourClass.from(hour: 0) == .earlyMorning)
        #expect(HourClass.from(hour: 5) == .earlyMorning)
        #expect(HourClass.from(hour: 6) == .amPeak)
        #expect(HourClass.from(hour: 9) == .amPeak)
        #expect(HourClass.from(hour: 10) == .midday)
        #expect(HourClass.from(hour: 14) == .midday)
        #expect(HourClass.from(hour: 15) == .pmPeak)
        #expect(HourClass.from(hour: 18) == .pmPeak)
        #expect(HourClass.from(hour: 19) == .evening)
        #expect(HourClass.from(hour: 22) == .evening)
        #expect(HourClass.from(hour: 23) == .late)
        // Anything out of range should still resolve to a valid bucket.
        #expect(HourClass.from(hour: -1) == .late)
        #expect(HourClass.from(hour: 99) == .late)
    }

    @Test func weekdayClassPeakWindows() {
        // Monday (weekday=2) 8am → weekdayPeak.
        #expect(WeekdayClass.from(weekday: 2, hour: 8) == .weekdayPeak)
        // Monday 11am → weekdayOffpeak.
        #expect(WeekdayClass.from(weekday: 2, hour: 11) == .weekdayOffpeak)
        // Friday (weekday=6) 5pm → weekdayPeak.
        #expect(WeekdayClass.from(weekday: 6, hour: 17) == .weekdayPeak)
        // Friday 8pm → weekdayOffpeak.
        #expect(WeekdayClass.from(weekday: 6, hour: 20) == .weekdayOffpeak)
        // Sunday (weekday=1) and Saturday (weekday=7) → weekend regardless of hour.
        #expect(WeekdayClass.from(weekday: 1, hour: 8) == .weekend)
        #expect(WeekdayClass.from(weekday: 7, hour: 17) == .weekend)
    }

    @Test func seasonByMonth() {
        #expect(Season.from(month: 12) == .winter)
        #expect(Season.from(month: 1) == .winter)
        #expect(Season.from(month: 2) == .winter)
        #expect(Season.from(month: 3) == .spring)
        #expect(Season.from(month: 5) == .spring)
        #expect(Season.from(month: 6) == .summer)
        #expect(Season.from(month: 8) == .summer)
        #expect(Season.from(month: 9) == .fall)
        #expect(Season.from(month: 11) == .fall)
    }

    @Test func hourOfWeekIsMondayAnchored() {
        // Monday=2 in Calendar terms.
        #expect(HourOfWeek.index(weekday: 2, hour: 0) == 0)
        #expect(HourOfWeek.index(weekday: 2, hour: 23) == 23)
        // Tuesday=3.
        #expect(HourOfWeek.index(weekday: 3, hour: 0) == 24)
        // Sunday=1 should wrap to slot 6*24 = 144.
        #expect(HourOfWeek.index(weekday: 1, hour: 0) == 144)
        #expect(HourOfWeek.index(weekday: 1, hour: 23) == 167)
    }
}
