import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("ArrivalBiasReader headline lookup")
struct ArrivalBiasReaderTests {
    private let reader = ArrivalBiasReader()

    /// Chicago calendar, fixed at a known weekday-morning instant, so
    /// `BiasCellKey.make` produces predictable bucket components for the
    /// reader's lookup. Thursday 2026-05-14 08:30 → amPeak, weekdayPeak,
    /// spring. Matches the canonical fixture in `BiasCellTests`.
    private static var chicagoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }

    private static var arrivalInstant: Date {
        let comps = DateComponents(
            calendar: chicagoCalendar,
            timeZone: chicagoCalendar.timeZone,
            year: 2026, month: 5, day: 14, hour: 8, minute: 30
        )
        return chicagoCalendar.date(from: comps)!
    }

    private func arrival(
        line: LineColor = .red,
        stopId: Int = 30074,
        directionCode: String = "1",
        arrivalAt: Date = arrivalInstant
    ) -> Arrival {
        Arrival(
            id: "\(line.rawValue)-\(stopId)-\(arrivalAt.timeIntervalSince1970)",
            line: line,
            runNumber: "418",
            destinationName: "95th/Dan Ryan",
            stationId: 40380,
            stationName: "Clark/Division",
            stopId: stopId,
            directionCode: directionCode,
            predictedAt: arrivalAt.addingTimeInterval(-300),
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    /// Welford state with a known mean/stddev/count — mirrors the helper
    /// in `ArrivalBiasCorrectionTests`.
    private func cell(count: Int, mean: Double, stddev: Double) -> BiasCell {
        let variance = stddev * stddev
        let m2 = variance * Double(max(count - 1, 0))
        return BiasCell(count: count, mean: mean, m2: m2, lastUpdatedAt: .distantPast)
    }

    // MARK: - Tests

    @Test func emptyArrivalsReturnsNil() {
        let result = reader.headlineCorrection(
            arrivals: [],
            cellLookup: { _ in nil }
        )
        #expect(result == nil)
    }

    @Test func headlineWithConfidentCellReturnsCorrection() {
        let confident = cell(count: 36, mean: 180, stddev: 60)
        let result = reader.headlineCorrection(
            arrivals: [arrival()],
            cellLookup: { _ in confident },
            calendar: Self.chicagoCalendar
        )
        #expect(result != nil)
        #expect(result?.direction == .apiEarly)
        #expect(result?.magnitudeSeconds == 180)
    }

    @Test func headlineWithMissingCellReturnsNil() {
        let result = reader.headlineCorrection(
            arrivals: [arrival()],
            cellLookup: { _ in nil },
            calendar: Self.chicagoCalendar
        )
        #expect(result == nil)
    }

    @Test func headlineWithUnderThresholdCellReturnsNil() {
        // 5 samples — fails the 12-count gate.
        let weak = cell(count: 5, mean: 200, stddev: 60)
        let result = reader.headlineCorrection(
            arrivals: [arrival()],
            cellLookup: { _ in weak },
            calendar: Self.chicagoCalendar
        )
        #expect(result == nil)
    }

    @Test func keyIsDerivedFromArrivalTimeNotNow() {
        // The bucket should reflect the *trip's* hour. We arrange for the
        // arrival to land in a known bucket (am-peak Thursday) and check
        // that the closure receives that exact key — NOT whatever bucket
        // wall-clock "now" happens to fall into when the test runs.
        let target = arrival()
        let spy = LookupSpy()
        let confident = cell(count: 36, mean: 180, stddev: 60)
        _ = reader.headlineCorrection(
            arrivals: [target],
            cellLookup: { key in
                spy.record(key)
                return confident
            },
            calendar: Self.chicagoCalendar
        )
        let observed = spy.keys.first
        #expect(observed != nil)
        #expect(observed?.line == LineColor.red.rawValue)
        #expect(observed?.stopId == "30074")
        #expect(observed?.direction == "1")
        #expect(observed?.hourClass == .amPeak)
        #expect(observed?.weekdayClass == .weekdayPeak)
        #expect(observed?.season == .spring)
    }

    @Test func keyUsesFirstArrival() {
        // When several arrivals are passed, only the first one drives the
        // lookup. The headline is the first by definition; downstream
        // dots represent successive trains, each in its own bucket.
        let first = arrival(stopId: 30074)
        let second = arrival(stopId: 30075) // different stop, ignored
        let spy = LookupSpy()
        _ = reader.headlineCorrection(
            arrivals: [first, second],
            cellLookup: { key in
                spy.record(key)
                return nil
            },
            calendar: Self.chicagoCalendar
        )
        #expect(spy.keys.count == 1)
        #expect(spy.keys.first?.stopId == "30074")
    }
}

/// Sendable-safe spy for recording `BiasCellKey` invocations from the
/// reader's `@Sendable` closure. A plain `var` capture fails Swift 6
/// concurrency checks; a class with a lock-guarded array passes cleanly.
private final class LookupSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [BiasCellKey] = []

    func record(_ key: BiasCellKey) {
        lock.lock()
        defer { lock.unlock() }
        _keys.append(key)
    }

    var keys: [BiasCellKey] {
        lock.lock()
        defer { lock.unlock() }
        return _keys
    }
}
