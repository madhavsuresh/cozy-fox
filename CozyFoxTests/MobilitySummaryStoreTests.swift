import Foundation
import Testing
import TransitModels
@testable import CozyFox

/// Race-with-clear regression tests for the Phase 0 learning stores. We
/// drive these the same way `WalkingDistanceStore` is exercised: pre-seed
/// the persisted JSON, kick off hydration, immediately call `clearAll()`,
/// then await hydration and assert the in-memory state was not clobbered by
/// the late-arriving disk data.
@MainActor
@Suite("MobilitySummaryStore")
struct MobilitySummaryStoreTests {
    @Test func clearAllBeforeHydrationFinishesWins() async throws {
        let url = Self.temporaryFile(name: "MobilitySummary-clear-race")
        let week = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            hourlyAnchorHistogram: [0: [.home: 3.0]]
        )
        try Self.seedPersisted(at: url, weeklies: [week], longTerm: .empty)

        let store = MobilitySummaryStore(fileURL: url)
        // Kick off hydration but do NOT await yet — we want the clear to
        // race the disk load.
        let hydration = Task { await store.hydrateFromDiskIfNeeded() }
        store.clearAll()
        await hydration.value

        #expect(store.weeklySummaries.isEmpty)
        #expect(store.longTermProfile == .empty)
    }

    @Test func sequentialHydrationLoadsPersistedData() async throws {
        let url = Self.temporaryFile(name: "MobilitySummary-warm")
        let week = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            hourlyAnchorHistogram: [42: [.home: 5.0]]
        )
        var longTerm = LongTermProfile.empty
        longTerm.fold(week, alpha: 1.0)
        try Self.seedPersisted(at: url, weeklies: [week], longTerm: longTerm)

        let store = MobilitySummaryStore(fileURL: url)
        await store.hydrateFromDiskIfNeeded()

        #expect(store.weeklySummaries.count == 1)
        #expect(store.weeklySummaries.first?.hourlyAnchorHistogram[42]?[.home] == 5.0)
        #expect(store.longTermProfile.hourlyAnchorHistogram[42]?[.home] == 5.0)
    }

    @Test func foldDropsOldRowsAndAggregatesByHour() async throws {
        let url = Self.temporaryFile(name: "MobilitySummary-fold")
        let store = MobilitySummaryStore(fileURL: url)
        await store.hydrateFromDiskIfNeeded()

        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-1 * 24 * 60 * 60)
        var profile = MobilityProfile.empty
        profile.recordRouteObservation(
            direction: .toWork,
            context: .atHome,
            line: .blue,
            stationId: 40380,
            busRoute: nil,
            busDirection: nil,
            at: old
        )
        profile.recordRouteObservation(
            direction: .toWork,
            context: .atHome,
            line: .blue,
            stationId: 40380,
            busRoute: nil,
            busDirection: nil,
            at: recent
        )

        let result = store.fold(profile: profile, now: now)
        // Only the 30-day-old observation is foldable; the 1-day-old one stays.
        #expect(result.foldedRouteObservationCount == 1)
        #expect(result.mutatedProfile.routeObservations.count == 1)
        #expect(store.weeklySummaries.count == 1)
        // The folded row maps to an L-station anchor for line/station 40380.
        let summary = store.weeklySummaries[0]
        let anchorTotals = summary.hourlyAnchorHistogram.values.reduce(into: 0) {
            $0 += $1[.lStation(stationId: 40380)] ?? 0
        }
        #expect(anchorTotals == 1.0)
    }

    @Test func foldPopulatesHourlyCorridorsFromRouteObservations() async throws {
        let url = Self.temporaryFile(name: "MobilitySummary-hourlyCorridors")
        let store = MobilitySummaryStore(fileURL: url)
        await store.hydrateFromDiskIfNeeded()

        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        // Two ages — both older than 14 days so they get folded.
        let morning = now.addingTimeInterval(-21 * 24 * 60 * 60)
        let evening = morning.addingTimeInterval(8 * 60 * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let originBucket = MobilityProfile.RouteLocation.bucketed(latitude: 41.95, longitude: -87.65)
        let destinationBucket = MobilityProfile.RouteLocation.bucketed(latitude: 41.88, longitude: -87.63)

        var profile = MobilityProfile.empty
        profile.recordRouteObservation(
            direction: .toWork,
            context: .atHome,
            line: .blue,
            stationId: 40380,
            busRoute: nil,
            busDirection: nil,
            origin: originBucket,
            destination: destinationBucket,
            at: morning,
            calendar: calendar
        )
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: .blue,
            stationId: 40380,
            busRoute: nil,
            busDirection: nil,
            origin: destinationBucket,
            destination: originBucket,
            at: evening,
            calendar: calendar
        )

        _ = store.fold(profile: profile, now: now)

        // Two different hours-of-week should be populated.
        let morningWeekday = calendar.component(.weekday, from: morning)
        let morningHour = calendar.component(.hour, from: morning)
        let eveningWeekday = calendar.component(.weekday, from: evening)
        let eveningHour = calendar.component(.hour, from: evening)
        let morningHourOfWeek = HourOfWeek.index(weekday: morningWeekday, hour: morningHour)
        let eveningHourOfWeek = HourOfWeek.index(weekday: eveningWeekday, hour: eveningHour)

        #expect(store.weeklySummaries.count == 1)
        let summary = store.weeklySummaries[0]
        // Each hour should have one corridor entry.
        #expect(summary.hourlyTopCorridors[morningHourOfWeek]?.count == 1)
        #expect(summary.hourlyTopCorridors[eveningHourOfWeek]?.count == 1)
        // Origin and destination should be bucketed via AnchorID.
        let morningCorridor = summary.hourlyTopCorridors[morningHourOfWeek]?.first
        #expect(morningCorridor?.frequency == 1.0)
        let eveningCorridor = summary.hourlyTopCorridors[eveningHourOfWeek]?.first
        #expect(eveningCorridor?.frequency == 1.0)
        // Long-term profile gets these too (alpha smoothed but non-empty).
        #expect(!store.longTermProfile.hourlyTopCorridors.isEmpty)
    }

    @Test func clearAllPersistsEmptyStateOnNextLoad() async throws {
        let url = Self.temporaryFile(name: "MobilitySummary-clear-persist")
        let week = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            hourlyAnchorHistogram: [0: [.home: 3.0]]
        )
        try Self.seedPersisted(at: url, weeklies: [week], longTerm: .empty)

        do {
            let store = MobilitySummaryStore(fileURL: url)
            await store.hydrateFromDiskIfNeeded()
            #expect(!store.weeklySummaries.isEmpty)
            store.clearAll()
            await store.persistNow()
        }

        // Reopen — clearAll should have wiped the file so a fresh store
        // hydrates empty.
        let reopened = MobilitySummaryStore(fileURL: url)
        await reopened.hydrateFromDiskIfNeeded()
        #expect(reopened.weeklySummaries.isEmpty)
    }

    // MARK: - Helpers

    static func temporaryFile(name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CozyFoxTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).json")
    }

    static func seedPersisted(
        at url: URL,
        weeklies: [WeeklySummary],
        longTerm: LongTermProfile
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = MobilitySummaryStore.Persisted(
            version: 1,
            weeklySummaries: weeklies,
            longTermProfile: longTerm
        )
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
