import Foundation
import Testing
@testable import CozyFox

@MainActor
@Suite("SuggestionSuppression")
struct SuggestionSuppressionTests {
    private static func makeStore() -> SuggestionSuppression {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestionSuppression-\(UUID().uuidString).json")
        return SuggestionSuppression(fileURL: url)
    }

    @Test func unknownCategoryIsNotSuppressed() {
        let store = Self.makeStore()
        #expect(!store.isSuppressed("homeward"))
    }

    @Test func suppressMarksThenLifts() {
        let store = Self.makeStore()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.suppress("homeward", for: 60 * 60, now: now)
        #expect(store.isSuppressed("homeward", now: now))
        // 30 min later — still suppressed.
        #expect(store.isSuppressed("homeward", now: now.addingTimeInterval(30 * 60)))
        // 2 hours later — expired.
        #expect(!store.isSuppressed("homeward", now: now.addingTimeInterval(2 * 60 * 60)))
    }

    @Test func clearDropsTheSpecificCategory() {
        let store = Self.makeStore()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.suppress("homeward", for: 60 * 60, now: now)
        store.suppress("pleasantSurprise:train:red", for: 60 * 60, now: now)
        store.clear("homeward")
        #expect(!store.isSuppressed("homeward", now: now))
        #expect(store.isSuppressed("pleasantSurprise:train:red", now: now))
    }

    @Test func clearAllDropsEverything() {
        let store = Self.makeStore()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.suppress("homeward", for: 60 * 60, now: now)
        store.suppress("pleasantSurprise:bus:22", for: 60 * 60, now: now)
        store.clearAll()
        #expect(!store.isSuppressed("homeward", now: now))
        #expect(!store.isSuppressed("pleasantSurprise:bus:22", now: now))
    }

    @Test func suppressReplacesExistingEntry() {
        let store = Self.makeStore()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.suppress("homeward", for: 60 * 60, now: now)
        // Lift sooner — pass a smaller window.
        store.suppress("homeward", for: 5 * 60, now: now)
        // 10 min later — expired (under the new window).
        #expect(!store.isSuppressed("homeward", now: now.addingTimeInterval(10 * 60)))
    }

    @Test func hydrateRestoresPersistedEntries() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuggestionSuppression-hydrate-\(UUID().uuidString).json")
        do {
            let store = SuggestionSuppression(fileURL: url)
            await store.hydrateFromDiskIfNeeded()
            store.suppress("homeward", for: 60 * 60, now: Date())
            try? await Task.sleep(nanoseconds: 800_000_000) // debounce
        }

        let reloaded = SuggestionSuppression(fileURL: url)
        await reloaded.hydrateFromDiskIfNeeded()
        #expect(reloaded.isSuppressed("homeward"))
    }
}
