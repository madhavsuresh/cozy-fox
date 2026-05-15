import Foundation
import Observation

/// Persistent, append-only store of recent bike rides recorded by
/// `BikeRouteSampler`. Caps the persisted set at `maxRoutes` (default
/// 20) to keep storage bounded; older entries get pruned on append.
///
/// Substrate, no consumer yet. A future clustering pipeline would read
/// these samples to learn the user's habitual bike routes ("you take
/// Milwaukee Ave home from work") without naming streets — the
/// fingerprint lives in the coordinate cluster, not in any external
/// lookup.
///
/// Lives on the main actor and is `@Observable` so a future Settings
/// surface can show "you've recorded N rides" without polling.
/// Persists to a single JSON file in `Caches/` (debounced writes).
@MainActor
@Observable
final class BikeRouteStore {
    private(set) var routes: [BikeRoute] = []

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadTask: Task<[BikeRoute], Never>?

    @ObservationIgnored
    private var hasLoadedFromDisk = false

    @ObservationIgnored
    private var shouldDiscardHydratedRoutes = false

    let maxRoutes: Int
    private let fileURL: URL

    init(fileURL: URL? = nil, maxRoutes: Int = 20) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.maxRoutes = maxRoutes
    }

    /// Hydrate from disk. Idempotent; subsequent calls early-return.
    func hydrateFromDiskIfNeeded() async {
        guard !hasLoadedFromDisk else { return }
        let task: Task<[BikeRoute], Never>
        if let existing = loadTask {
            task = existing
        } else {
            let url = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadPersistedRoutes(from: url)
            }
            loadTask = task
        }
        let loaded = await task.value
        guard !hasLoadedFromDisk else { return }
        loadTask = nil
        hasLoadedFromDisk = true
        guard !shouldDiscardHydratedRoutes else { return }
        // Loaded routes go AHEAD of any in-memory routes recorded
        // before hydration finished, by recordedAt time, then trimmed.
        let merged = (loaded + routes).sorted { $0.startedAt > $1.startedAt }
        routes = Array(merged.prefix(maxRoutes))
    }

    /// Append a new route. Older entries beyond `maxRoutes` get pruned
    /// from the tail. Persistence is debounced.
    func record(_ route: BikeRoute) {
        var next = [route] + routes
        if next.count > maxRoutes {
            next = Array(next.prefix(maxRoutes))
        }
        routes = next
        persistDebounced()
    }

    /// Wipe all recorded routes. Wired into Settings → "Reset
    /// learning".
    func clearAll() {
        loadTask?.cancel()
        loadTask = nil
        hasLoadedFromDisk = true
        shouldDiscardHydratedRoutes = true
        routes.removeAll()
        persistDebounced()
    }

    // MARK: - Persistence

    private struct Persisted: Codable, Sendable {
        let version: Int
        let routes: [BikeRoute]
    }

    private static func defaultFileURL() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("bike-routes.json")
    }

    nonisolated private static func loadPersistedRoutes(from fileURL: URL) -> [BikeRoute] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return []
        }
        guard decoded.version == 1 else { return [] }
        return decoded.routes
    }

    private func persistDebounced() {
        persistTask?.cancel()
        let snapshot = Persisted(version: 1, routes: routes)
        let url = fileURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
