import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("LastTrainSafety")
struct LastTrainSafetyTests {
    private let detector = LastTrainSafety()
    private static var chicagoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }
    private static let lateNight = chicagoCalendar.date(from: DateComponents(
        calendar: chicagoCalendar, timeZone: chicagoCalendar.timeZone,
        year: 2026, month: 5, day: 14, hour: 23
    ))!
    private static let earlyEvening = chicagoCalendar.date(from: DateComponents(
        calendar: chicagoCalendar, timeZone: chicagoCalendar.timeZone,
        year: 2026, month: 5, day: 14, hour: 18
    ))!

    private func arrival(at minutesFromNow: Double, base: Date = lateNight) -> Arrival {
        Arrival(
            id: UUID().uuidString,
            line: .brown,
            runNumber: "401",
            destinationName: "Kimball",
            stationId: 40380,
            stationName: "Sedgwick",
            stopId: 30173,
            directionCode: "1",
            predictedAt: base,
            arrivalAt: base.addingTimeInterval(minutesFromNow * 60),
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    // MARK: - Happy path

    @Test func warnsWhenSparseLateNight() {
        // 11 PM, 2 upcoming arrivals, latest is 25 min away.
        let arrivals = [arrival(at: 10), arrival(at: 25)]
        let warning = detector.warning(
            forArrivals: arrivals,
            now: Self.lateNight,
            calendar: Self.chicagoCalendar
        )
        #expect(warning != nil)
        #expect(warning?.minutesUntilLast == 25)
    }

    // MARK: - Gates

    @Test func quietBeforeLateNight() {
        // 6 PM, same sparse pattern — no warning.
        let arrivals = [
            arrival(at: 10, base: Self.earlyEvening),
            arrival(at: 25, base: Self.earlyEvening)
        ]
        let warning = detector.warning(
            forArrivals: arrivals,
            now: Self.earlyEvening,
            calendar: Self.chicagoCalendar
        )
        #expect(warning == nil)
    }

    @Test func quietWhenServiceIsRobust() {
        // 11 PM, but 5 upcoming arrivals — not winding down.
        let arrivals = (1...5).map { Double($0) }.map { arrival(at: $0 * 5) }
        let warning = detector.warning(
            forArrivals: arrivals,
            now: Self.lateNight,
            calendar: Self.chicagoCalendar
        )
        #expect(warning == nil)
    }

    @Test func quietWhenLatestArrivalIsFar() {
        // 11 PM, 2 arrivals but latest is 50 min out — not last-call.
        let arrivals = [arrival(at: 10), arrival(at: 50)]
        let warning = detector.warning(
            forArrivals: arrivals,
            now: Self.lateNight,
            calendar: Self.chicagoCalendar
        )
        #expect(warning == nil)
    }

    @Test func quietWhenNoArrivals() {
        let warning = detector.warning(
            forArrivals: [],
            now: Self.lateNight,
            calendar: Self.chicagoCalendar
        )
        #expect(warning == nil)
    }

    @Test func ignoresPastArrivals() {
        // 11 PM, one past arrival + one future arrival within window.
        let past = arrival(at: -10)
        let future = arrival(at: 20)
        let warning = detector.warning(
            forArrivals: [past, future],
            now: Self.lateNight,
            calendar: Self.chicagoCalendar
        )
        #expect(warning != nil)
        #expect(warning?.minutesUntilLast == 20)
    }

    @Test func customThresholdLowersTheBar() {
        // 5 upcoming arrivals — default threshold suppresses. Custom
        // threshold of 6 lets it through.
        let arrivals = (1...5).map { Double($0) }.map { arrival(at: $0 * 5) }
        let warning = detector.warning(
            forArrivals: arrivals,
            now: Self.lateNight,
            consideredLastThreshold: 6,
            calendar: Self.chicagoCalendar
        )
        // But — latest is 25 min, threshold met (5 ≤ 6) → warning!
        // Confirms the threshold parameter is the gate.
        #expect(warning != nil)
        #expect(warning?.minutesUntilLast == 25)
    }
}
