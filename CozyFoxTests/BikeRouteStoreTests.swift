import Foundation
import Testing
@testable import CozyFox

@MainActor
@Suite("BikeRouteStore")
struct BikeRouteStoreTests {
    private static func makeStore(maxRoutes: Int = 20) -> BikeRouteStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeRouteStore-\(UUID().uuidString).json")
        return BikeRouteStore(fileURL: url, maxRoutes: maxRoutes)
    }

    private func makeRoute(
        startedAt: Date,
        durationMinutes: Double = 30,
        sampleCount: Int = 5
    ) -> BikeRoute {
        let samples = (0..<sampleCount).map { i in
            BikeRoute.Sample(
                latitude: 41.9 + Double(i) * 0.001,
                longitude: -87.65,
                recordedAt: startedAt.addingTimeInterval(Double(i) * 60)
            )
        }
        return BikeRoute(
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationMinutes * 60),
            samples: samples
        )
    }

    @Test func startsEmpty() {
        let store = Self.makeStore()
        #expect(store.routes.isEmpty)
    }

    @Test func recordAppendsToFront() {
        let store = Self.makeStore()
        let route = makeRoute(startedAt: Date())
        store.record(route)
        #expect(store.routes.count == 1)
        #expect(store.routes.first?.id == route.id)
    }

    @Test func newerRoutesGoFirst() {
        let store = Self.makeStore()
        let older = makeRoute(startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let newer = makeRoute(startedAt: Date(timeIntervalSinceReferenceDate: 800_000_600))
        store.record(older)
        store.record(newer)
        #expect(store.routes.first?.id == newer.id)
        #expect(store.routes.last?.id == older.id)
    }

    @Test func capLimitsRetainedCount() {
        let store = Self.makeStore(maxRoutes: 3)
        for i in 0..<5 {
            let route = makeRoute(
                startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(i) * 600)
            )
            store.record(route)
        }
        #expect(store.routes.count == 3)
        // Most recent (i=4) should be first; oldest retained should be i=2.
        let recordedAt = store.routes.map(\.startedAt.timeIntervalSinceReferenceDate)
        let base: TimeInterval = 800_000_000
        let expected: [TimeInterval] = [
            base + 4 * 600,
            base + 3 * 600,
            base + 2 * 600
        ]
        #expect(recordedAt == expected)
    }

    @Test func clearAllEmptiesTheStore() {
        let store = Self.makeStore()
        store.record(makeRoute(startedAt: Date()))
        store.record(makeRoute(startedAt: Date().addingTimeInterval(60)))
        #expect(store.routes.count == 2)
        store.clearAll()
        #expect(store.routes.isEmpty)
    }

    @Test func hydrateRestoresPersistedRoutes() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeRouteStore-hydrate-\(UUID().uuidString).json")
        do {
            let store = BikeRouteStore(fileURL: url)
            store.record(makeRoute(
                startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)
            ))
            // Give the debounced persistence task a moment to flush.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        let reloaded = BikeRouteStore(fileURL: url)
        await reloaded.hydrateFromDiskIfNeeded()
        #expect(reloaded.routes.count == 1)
    }
}
