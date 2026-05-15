import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BiasCorrectionReader / BiasCellLookupReader")
struct BiasCorrectionReaderTests {
    /// Chicago calendar at a fixed weekday-morning instant, so
    /// `BiasCellKey.make` produces deterministic bucket components.
    /// Matches the canonical fixture in `BiasCellTests` /
    /// `ArrivalBiasReaderTests`.
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

    /// Synthesize a Welford state with known mean/stddev/count — same
    /// shape used in `ArrivalBiasCorrectionTests`.
    private func cell(count: Int, mean: Double, stddev: Double) -> BiasCell {
        let variance = stddev * stddev
        let m2 = variance * Double(max(count - 1, 0))
        return BiasCell(count: count, mean: mean, m2: m2, lastUpdatedAt: .distantPast)
    }

    @Test func emptyReaderReturnsNilForEveryQuery() {
        let reader = EmptyBiasCorrectionReader()
        let train = BiasArrivalRef.train(line: .red, stopID: 30074, directionCode: "1")
        let bus = BiasArrivalRef.bus(route: "22", stopID: 1234, directionName: "Northbound")
        #expect(reader.correction(for: train, at: Self.arrivalInstant) == nil)
        #expect(reader.correction(for: bus, at: Self.arrivalInstant) == nil)
    }

    /// Reference-typed accumulator so the `@Sendable` closure can mutate
    /// across the isolation boundary without tripping Swift 6 strict
    /// concurrency. Synchronous usage in these tests means no real
    /// races; `@unchecked Sendable` is the conventional escape hatch.
    private final class LookupCollector: @unchecked Sendable {
        var keys: [BiasCellKey] = []
    }

    @Test func trainLookupKeyMatchesArrivalBiasReader() {
        // Same arrival shape used by `ArrivalBiasReader.headlineCorrection`.
        // Both readers should hit the same cell when given the same
        // (line, stopId, direction, when, calendar) inputs.
        let confident = cell(count: 36, mean: 180, stddev: 60)
        let collector = LookupCollector()
        let portfolioReader = BiasCellLookupReader(
            cellLookup: { key in
                collector.keys.append(key)
                return confident
            },
            calendar: Self.chicagoCalendar
        )
        let result = portfolioReader.correction(
            for: .train(line: .red, stopID: 30074, directionCode: "1"),
            at: Self.arrivalInstant
        )

        // Confirm the same key shape the existing reader constructs.
        let expectedKey = BiasCellKey.make(
            line: LineColor.red.rawValue,
            stopId: "30074",
            direction: "1",
            at: Self.arrivalInstant,
            calendar: Self.chicagoCalendar
        )
        #expect(collector.keys == [expectedKey])
        #expect(result?.direction == .apiEarly)
        #expect(result?.magnitudeSeconds == 180)
    }

    @Test func busLookupKeysOnRouteNotLineColor() {
        // Bus uses the route string ("22") as the `line` slot in
        // `BiasCellKey` — not a `LineColor.rawValue`. Verify the
        // reader honors this.
        let collector = LookupCollector()
        let reader = BiasCellLookupReader(
            cellLookup: { key in
                collector.keys.append(key)
                return nil
            },
            calendar: Self.chicagoCalendar
        )
        _ = reader.correction(
            for: .bus(route: "22", stopID: 1234, directionName: "Northbound"),
            at: Self.arrivalInstant
        )
        #expect(collector.keys.count == 1)
        #expect(collector.keys.first?.line == "22")
        #expect(collector.keys.first?.stopId == "1234")
        #expect(collector.keys.first?.direction == "Northbound")
    }

    @Test func confidenceGateRejectsLowSampleCount() {
        // Sample count below `ArrivalBiasCorrection.from(cell:)`'s
        // default minSampleCount of 12 → returns nil even though the
        // store had a cell.
        let weak = cell(count: 5, mean: 180, stddev: 60)
        let reader = BiasCellLookupReader(
            cellLookup: { _ in weak },
            calendar: Self.chicagoCalendar
        )
        let result = reader.correction(
            for: .train(line: .red, stopID: 30074, directionCode: "1"),
            at: Self.arrivalInstant
        )
        #expect(result == nil)
    }

    @Test func biasArrivalRefHashesByCase() {
        // Same identifiers in different cases must produce distinct
        // values — train(red, 1234, "1") ≠ bus("red", 1234, "1").
        let train = BiasArrivalRef.train(line: .red, stopID: 1234, directionCode: "1")
        let bus = BiasArrivalRef.bus(route: "red", stopID: 1234, directionName: "1")
        #expect(train != bus)
    }
}
