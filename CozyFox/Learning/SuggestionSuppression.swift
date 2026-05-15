import Foundation
import Observation

/// Persistent suppression tracker for dismissable dashboard suggestions
/// (head-home, pleasant-surprise, etc.). Each category can have its
/// own `suppressedUntil` timestamp — when the user dismisses one
/// suggestion, the suggester for that category checks here before
/// firing again.
///
/// Lives on the main actor and is `@Observable` so dashboards re-render
/// when the suppression changes. Persists to a single JSON file in
/// `Caches/` so dismissals survive cold-starts. Tiny file (a dict of
/// keys to dates), trivially debounced.
///
/// Categories are open-ended strings — callers compose them. Common
/// shapes:
/// - `"homeward"` — single key for the head-home tile.
/// - `"pleasantSurprise:train:red"` — keyed per (mode, routeId) so
///   dismissing "try the Red line today" doesn't suppress "try the
///   22 Clark today."
@MainActor
@Observable
final class SuggestionSuppression {
    /// Map from category key to the moment the suppression expires.
    /// Entries older than `now` are considered expired but stay on
    /// disk until the next write — cheaper than scrubbing on every
    /// `isSuppressed` check.
    private(set) var suppressedUntil: [String: Date] = [:]

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadTask: Task<[String: Date], Never>?

    @ObservationIgnored
    private var hasLoadedFromDisk = false

    @ObservationIgnored
    private var shouldDiscardHydrated = false

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// Hydrate from disk. Idempotent.
    func hydrateFromDiskIfNeeded() async {
        guard !hasLoadedFromDisk else { return }
        let task: Task<[String: Date], Never>
        if let existing = loadTask {
            task = existing
        } else {
            let url = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadPersisted(from: url)
            }
            loadTask = task
        }
        let loaded = await task.value
        guard !hasLoadedFromDisk else { return }
        loadTask = nil
        hasLoadedFromDisk = true
        guard !shouldDiscardHydrated else { return }
        // Merge: any in-memory entries set before hydration completed
        // win — those are user actions during boot, and they're more
        // current than disk.
        var merged = loaded
        for (key, value) in suppressedUntil { merged[key] = value }
        suppressedUntil = merged
    }

    /// Mark `category` as suppressed for `duration` seconds from now.
    /// Replaces any existing entry for the same key.
    func suppress(_ category: String, for duration: TimeInterval, now: Date = .now) {
        suppressedUntil[category] = now.addingTimeInterval(duration)
        persistDebounced()
    }

    /// `true` when `category` was suppressed and the entry hasn't yet
    /// expired. `false` when never suppressed, expired, or explicitly
    /// cleared.
    func isSuppressed(_ category: String, now: Date = .now) -> Bool {
        guard let until = suppressedUntil[category] else { return false }
        return now < until
    }

    /// Drop a single category's suppression.
    func clear(_ category: String) {
        guard suppressedUntil.removeValue(forKey: category) != nil else { return }
        persistDebounced()
    }

    /// Drop every category. Wired into Settings → "Reset learning".
    func clearAll() {
        loadTask?.cancel()
        loadTask = nil
        hasLoadedFromDisk = true
        shouldDiscardHydrated = true
        suppressedUntil.removeAll()
        persistDebounced()
    }

    // MARK: - Persistence

    private struct Persisted: Codable, Sendable {
        let version: Int
        let entries: [String: Date]
    }

    private static func defaultFileURL() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("suggestion-suppression.json")
    }

    nonisolated private static func loadPersisted(from fileURL: URL) -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data),
              decoded.version == 1
        else { return [:] }
        return decoded.entries
    }

    private func persistDebounced() {
        persistTask?.cancel()
        let snapshot = Persisted(version: 1, entries: suppressedUntil)
        let url = fileURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
