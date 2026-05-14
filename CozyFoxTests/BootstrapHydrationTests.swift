import Foundation
import Testing
import TransitModels
@testable import CozyFox

/// `AppViewModel.bootstrap()` starts hydration for the walking store, the
/// mobility summary store, and the arrival-bias store as three sibling
/// tasks, then awaits all three before kicking off `refreshIfNeeded()`.
///
/// Standing up the full `AppViewModel` from XCTest is awkward (it requires a
/// `TransitStore`, region monitoring, etc.), so this test exercises the
/// same parallel-await pattern directly against the two new stores. The
/// invariant we care about is that both stores can be hydrated
/// concurrently without locking each other, which would tear down on the
/// real bootstrap immediately.
@MainActor
@Suite("Bootstrap parallel hydration")
struct BootstrapHydrationTests {
    @Test func bothStoresHydrateConcurrentlyFromMissingFiles() async {
        let mobilityURL = MobilitySummaryStoreTests.temporaryFile(name: "Bootstrap-mob-missing")
        let biasURL = MobilitySummaryStoreTests.temporaryFile(name: "Bootstrap-bias-missing")
        try? FileManager.default.removeItem(at: mobilityURL)
        try? FileManager.default.removeItem(at: biasURL)

        let mobilityStore = MobilitySummaryStore(fileURL: mobilityURL)
        let biasStore = ArrivalBiasStore(fileURL: biasURL)

        async let mobilityHydration: Void = mobilityStore.hydrateFromDiskIfNeeded()
        async let biasHydration: Void = biasStore.hydrateFromDiskIfNeeded()
        _ = await (mobilityHydration, biasHydration)

        // Empty files → empty stores. Important: subsequent
        // `hydrateFromDiskIfNeeded` calls must early-return rather than
        // re-load.
        #expect(mobilityStore.weeklySummaries.isEmpty)
        #expect(biasStore.cells.isEmpty)

        await mobilityStore.hydrateFromDiskIfNeeded()
        await biasStore.hydrateFromDiskIfNeeded()
        #expect(mobilityStore.weeklySummaries.isEmpty)
        #expect(biasStore.cells.isEmpty)
    }

    @Test func bothStoresHydrateConcurrentlyFromPreSeededFiles() async throws {
        let mobilityURL = MobilitySummaryStoreTests.temporaryFile(name: "Bootstrap-mob-seeded")
        let biasURL = MobilitySummaryStoreTests.temporaryFile(name: "Bootstrap-bias-seeded")
        let week = WeeklySummary(weekStart: Date(), hourlyAnchorHistogram: [0: [.home: 1.0]])
        try MobilitySummaryStoreTests.seedPersisted(at: mobilityURL, weeklies: [week], longTerm: .empty)

        let key = BiasCellKey(
            line: "Brown", stopId: "1", direction: "N",
            hourClass: .amPeak, weekdayClass: .weekdayPeak, season: .spring
        )
        var seededCell = BiasCell()
        seededCell.recordSample(45, at: Date())
        try ArrivalBiasStoreTests.seedPersisted(at: biasURL, entries: [(key, seededCell)])

        let mobilityStore = MobilitySummaryStore(fileURL: mobilityURL)
        let biasStore = ArrivalBiasStore(fileURL: biasURL)

        async let mobilityHydration: Void = mobilityStore.hydrateFromDiskIfNeeded()
        async let biasHydration: Void = biasStore.hydrateFromDiskIfNeeded()
        _ = await (mobilityHydration, biasHydration)

        #expect(mobilityStore.weeklySummaries.count == 1)
        #expect(biasStore.cells[key]?.count == 1)
    }
}
