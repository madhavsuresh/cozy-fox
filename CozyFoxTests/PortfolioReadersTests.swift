import Foundation
import Testing
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("PortfolioReaders — app-side conformances")
struct PortfolioReadersTests {
    /// Chicago calendar fixed at a weekday-morning instant so
    /// `BiasCellKey.make` produces predictable bucket components.
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

    private static func biasCell(count: Int, mean: Double, stddev: Double) -> BiasCell {
        let variance = stddev * stddev
        let m2 = variance * Double(max(count - 1, 0))
        return BiasCell(count: count, mean: mean, m2: m2, lastUpdatedAt: .distantPast)
    }

    private static func temporaryWalkingFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PortfolioReadersTests-walking-\(UUID().uuidString).json")
    }

    private static func temporaryBiasFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PortfolioReadersTests-bias-\(UUID().uuidString).json")
    }

    // MARK: - BiasCorrectionReader conformance

    @Test func biasReaderSeesCellsRecordedInStore() {
        let store = ArrivalBiasStore(fileURL: Self.temporaryBiasFile())
        let key = BiasCellKey.make(
            line: LineColor.red.rawValue,
            stopId: "30074",
            direction: "1",
            at: Self.arrivalInstant,
            calendar: Self.chicagoCalendar
        )
        // Seed 36 samples of +180s so the cell easily clears the
        // confidence gate.
        for _ in 0..<36 {
            store.recordSample(key: key, deltaSeconds: 180, at: Self.arrivalInstant)
        }

        let reader = store.makeBiasCorrectionReader(calendar: Self.chicagoCalendar)
        let correction = reader.correction(
            for: .train(line: .red, stopID: 30074, directionCode: "1"),
            at: Self.arrivalInstant
        )

        #expect(correction != nil)
        #expect(correction?.direction == .apiEarly)
        #expect(abs((correction?.magnitudeSeconds ?? 0) - 180) < 1e-9)
    }

    @Test func biasReaderIsFrozenAtConstruction() {
        // A reader returned by `makeBiasCorrectionReader()` must not
        // observe samples recorded into the store after the call. This
        // matters because the evaluator runs off-main and we don't want
        // it racing the store.
        let store = ArrivalBiasStore(fileURL: Self.temporaryBiasFile())
        let reader = store.makeBiasCorrectionReader(calendar: Self.chicagoCalendar)

        let key = BiasCellKey.make(
            line: LineColor.red.rawValue,
            stopId: "30074",
            direction: "1",
            at: Self.arrivalInstant,
            calendar: Self.chicagoCalendar
        )
        for _ in 0..<36 {
            store.recordSample(key: key, deltaSeconds: 180, at: Self.arrivalInstant)
        }

        // The reader was built before recordSample fired → should see nothing.
        let correction = reader.correction(
            for: .train(line: .red, stopID: 30074, directionCode: "1"),
            at: Self.arrivalInstant
        )
        #expect(correction == nil)
    }

    @Test func biasReaderReturnsNilForUnknownKey() {
        let store = ArrivalBiasStore(fileURL: Self.temporaryBiasFile())
        let reader = store.makeBiasCorrectionReader(calendar: Self.chicagoCalendar)
        let correction = reader.correction(
            for: .bus(route: "22", stopID: 9999, directionName: "Northbound"),
            at: Self.arrivalInstant
        )
        #expect(correction == nil)
    }

    // MARK: - WalkingDistanceReader conformance

    @Test func walkingReaderReturnsScaledTimeForKnownStation() {
        let store = WalkingDistanceStore(fileURL: Self.temporaryWalkingFile())
        let origin = (lat: 41.95, lon: -87.66)
        store.record(
            meters: 400,
            expectedTravelTime: 360,
            origin: origin,
            stationId: 40380
        )

        let reader = store.makeWalkingDistanceReader()
        let result = reader.walkSeconds(from: origin, to: .lStation(40380))
        // No walk-speed samples recorded → ratio defaults to 1.0.
        #expect(result == 360)
    }

    @Test func walkingReaderAppliesConfidentWalkSpeedRatio() {
        let store = WalkingDistanceStore(fileURL: Self.temporaryWalkingFile())
        let origin = (lat: 41.95, lon: -87.66)
        store.record(meters: 400, expectedTravelTime: 360, origin: origin, stationId: 40380)
        // 5+ samples to clear `confidentRatio()`'s default gate. Each
        // sample says "I walked 50% faster than MapKit predicted."
        for _ in 0..<6 {
            store.recordWalkSpeedSample(
                WalkSpeedSample(
                    actualSeconds: 60,
                    expectedSeconds: 120,
                    recordedAt: .distantPast
                )
            )
        }
        let reader = store.makeWalkingDistanceReader()
        let result = reader.walkSeconds(from: origin, to: .lStation(40380))
        // Walk-speed mean = 0.5; 360 * 0.5 = 180.
        #expect(result != nil)
        if let result {
            #expect(abs(result - 180) < 1e-6)
        }
    }

    @Test func walkingReaderReturnsNilWhenEntryExpired() {
        let store = WalkingDistanceStore(
            fileURL: Self.temporaryWalkingFile(),
            freshnessTTL: 1
        )
        let origin = (lat: 41.95, lon: -87.66)
        store.record(meters: 400, expectedTravelTime: 360, origin: origin, stationId: 40380)

        // Set reader's reference time to well past the 1-second TTL.
        let reader = store.makeWalkingDistanceReader(now: Date().addingTimeInterval(60))
        let result = reader.walkSeconds(from: origin, to: .lStation(40380))
        #expect(result == nil)
    }

    @Test func walkingReaderReturnsNilForLPlatformKind() {
        // v0 limitation: the cache is keyed by station, not platform.
        // Callers that need platform-level walk time must resolve to
        // the parent station via `LStationCatalog` first.
        let store = WalkingDistanceStore(fileURL: Self.temporaryWalkingFile())
        let origin = (lat: 41.95, lon: -87.66)
        store.record(meters: 400, expectedTravelTime: 360, origin: origin, stationId: 40380)

        let reader = store.makeWalkingDistanceReader()
        let result = reader.walkSeconds(from: origin, to: .lPlatform(30173))
        #expect(result == nil)
    }

    @Test func walkingReaderIsFrozenAtConstruction() {
        let store = WalkingDistanceStore(fileURL: Self.temporaryWalkingFile())
        let origin = (lat: 41.95, lon: -87.66)
        let reader = store.makeWalkingDistanceReader()
        // Record after building the reader; the reader shouldn't see it.
        store.record(meters: 400, expectedTravelTime: 360, origin: origin, stationId: 40380)
        let result = reader.walkSeconds(from: origin, to: .lStation(40380))
        #expect(result == nil)
    }
}
