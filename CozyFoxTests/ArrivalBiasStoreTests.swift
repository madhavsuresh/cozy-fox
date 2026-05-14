import Foundation
import Testing
import TransitModels
@testable import CozyFox

@MainActor
@Suite("ArrivalBiasStore")
struct ArrivalBiasStoreTests {
    @Test func clearAllBeforeHydrationFinishesWins() async throws {
        let url = Self.temporaryFile(name: "ArrivalBias-clear-race")
        let key = BiasCellKey(
            line: "Brown",
            stopId: "40380",
            direction: "Loop-bound",
            hourClass: .amPeak,
            weekdayClass: .weekdayPeak,
            season: .spring
        )
        var seeded = BiasCell()
        seeded.recordSample(60, at: Date())
        try Self.seedPersisted(at: url, entries: [(key, seeded)])

        let store = ArrivalBiasStore(fileURL: url)
        let hydration = Task { await store.hydrateFromDiskIfNeeded() }
        store.clearAll()
        await hydration.value

        #expect(store.cells.isEmpty)
    }

    @Test func recordSampleSurvivesHydrationRace() async throws {
        let url = Self.temporaryFile(name: "ArrivalBias-record-race")
        let key = BiasCellKey(
            line: "Brown",
            stopId: "40380",
            direction: "Loop-bound",
            hourClass: .amPeak,
            weekdayClass: .weekdayPeak,
            season: .spring
        )
        var seeded = BiasCell()
        seeded.recordSample(120, at: Date())
        try Self.seedPersisted(at: url, entries: [(key, seeded)])

        let store = ArrivalBiasStore(fileURL: url)
        let hydration = Task { await store.hydrateFromDiskIfNeeded() }
        // Record a fresh sample mid-flight. The store should merge the
        // disk-loaded cell underneath it (i.e., the new sample is the
        // authoritative cell once hydration lands).
        store.recordSample(key: key, deltaSeconds: 30, at: Date())
        await hydration.value

        let cell = store.snapshot(key: key)
        #expect(cell?.count == 1)
        #expect(cell?.mean == 30)
    }

    @Test func decayDropsCellsBelowOne() async throws {
        let url = Self.temporaryFile(name: "ArrivalBias-decay")
        let store = ArrivalBiasStore(fileURL: url)
        await store.hydrateFromDiskIfNeeded()
        let key = BiasCellKey(
            line: "Red", stopId: "1", direction: "N",
            hourClass: .late, weekdayClass: .weekend, season: .summer
        )
        let when = Date(timeIntervalSinceReferenceDate: 770_000_000)
        store.recordSample(key: key, deltaSeconds: 90, at: when)

        let muchLater = when.addingTimeInterval(365 * 86_400)
        store.decay(halfLifeDays: 30, now: muchLater)
        // One year, 30-day half-life → factor ≈ 2^-12 ≈ 0.000244, count goes to 0.
        #expect(store.snapshot(key: key) == nil)
    }

    // MARK: - Helpers

    static func temporaryFile(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
    }

    static func seedPersisted(
        at url: URL,
        entries: [(BiasCellKey, BiasCell)]
    ) throws {
        struct Persisted: Codable {
            let version: Int
            let cells: [ArrivalBiasStore.StoredCell]
        }
        let payload = Persisted(
            version: 1,
            cells: entries.map { ArrivalBiasStore.StoredCell(key: $0.0, cell: $0.1) }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
