import Foundation
import Observation
import SwiftyH3

struct WalkingDistance: Codable, Equatable, Sendable {
    let meters: Double
    let expectedTravelTime: TimeInterval
    let cachedAt: Date
}

enum AccessTravelMode: String, Codable, Sendable {
    case walking
    case cycling
}

struct AccessRouteDistances: Codable, Equatable, Sendable {
    var walking: WalkingDistance?
    var cycling: WalkingDistance?

    init(walking: WalkingDistance? = nil, cycling: WalkingDistance? = nil) {
        self.walking = walking
        self.cycling = cycling
    }

    func distance(for mode: AccessTravelMode) -> WalkingDistance? {
        switch mode {
        case .walking: walking
        case .cycling: cycling
        }
    }

    mutating func set(_ distance: WalkingDistance, for mode: AccessTravelMode) {
        switch mode {
        case .walking: walking = distance
        case .cycling: cycling = distance
        }
    }

    func invalidated(at stamp: Date) -> AccessRouteDistances {
        AccessRouteDistances(
            walking: walking.map {
                WalkingDistance(
                    meters: $0.meters,
                    expectedTravelTime: $0.expectedTravelTime,
                    cachedAt: stamp
                )
            },
            cycling: cycling.map {
                WalkingDistance(
                    meters: $0.meters,
                    expectedTravelTime: $0.expectedTravelTime,
                    cachedAt: stamp
                )
            }
        )
    }
}

/// Persistent cache of MapKit access-route lookups, keyed on a ~50m origin
/// grid + destination id. Lives on the main actor and is `@Observable` so
/// SwiftUI re-renders when MapKit results land. Persists to a JSON file in
/// `Caches/`, small enough that we just rewrite the whole file on change
/// (debounced).
@MainActor
@Observable
final class WalkingDistanceStore {
    private(set) var distances: [String: AccessRouteDistances] = [:]

    @ObservationIgnored
    private var inflight: Set<String> = []

    @ObservationIgnored
    private var failures: [String: Date] = [:]

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadTask: Task<[String: AccessRouteDistances], Never>?

    @ObservationIgnored
    private var hasLoadedFromDisk = false

    @ObservationIgnored
    private var shouldDiscardHydratedDistances = false

    @ObservationIgnored
    private var shouldInvalidateHydratedDistances = false

    let freshnessTTL: TimeInterval
    let negativeCacheTTL: TimeInterval

    private let fileURL: URL

    init(
        fileURL: URL? = nil,
        freshnessTTL: TimeInterval = 24 * 60 * 60,
        negativeCacheTTL: TimeInterval = 5 * 60
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.freshnessTTL = freshnessTTL
        self.negativeCacheTTL = negativeCacheTTL
    }

    func hydrateFromDiskIfNeeded() async {
        guard !hasLoadedFromDisk else { return }
        let task: Task<[String: AccessRouteDistances], Never>
        if let existing = loadTask {
            task = existing
        } else {
            let url = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadPersistedDistances(from: url)
            }
            loadTask = task
        }

        var loaded = await task.value
        guard !hasLoadedFromDisk else { return }
        loadTask = nil
        hasLoadedFromDisk = true
        guard !shouldDiscardHydratedDistances else { return }
        if shouldInvalidateHydratedDistances {
            let stamp = Date.distantPast
            loaded = loaded.mapValues { $0.invalidated(at: stamp) }
        }
        distances.merge(loaded) { current, _ in current }
    }

    private static func defaultFileURL() -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("walking-distances.json")
    }

    /// H3 resolution 10 (~66m hex edge) is the right granularity for
    /// "user standing in roughly the same spot" — GPS jitter inside a
    /// lobby, sidewalk, or storefront stays inside a single cell, and the
    /// cell IDs are a stable industry standard rather than ad-hoc math.
    /// Falls back to a raw coord string on the (essentially impossible)
    /// chance H3 rejects the input as out-of-range.
    static let cellResolution: H3Cell.Resolution = .res10

    static func bucketKey(origin: (lat: Double, lon: Double), destinationKey: String) -> String {
        let cellID: String
        if let cell = try? H3LatLng(
            latitudeDegs: origin.lat,
            longitudeDegs: origin.lon
        ).cell(at: cellResolution) {
            cellID = String(cell.id)
        } else {
            cellID = "raw-\(origin.lat)-\(origin.lon)"
        }
        return "\(cellID)_\(destinationKey)"
    }

    static func stationDestinationKey(stationId: Int) -> String {
        String(stationId)
    }

    static func busStopDestinationKey(stopId: Int) -> String {
        "bus-\(stopId)"
    }

    static func metraStationDestinationKey(stationId: String) -> String {
        "metra-\(stationId)"
    }

    static func intercampusStopDestinationKey(stopId: String) -> String {
        "intercampus-\(stopId)"
    }

    static func bucketKey(origin: (lat: Double, lon: Double), stationId: Int) -> String {
        bucketKey(origin: origin, destinationKey: stationDestinationKey(stationId: stationId))
    }

    /// Fresh entry, or nil if missing or past TTL.
    func fresh(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        let key = Self.bucketKey(origin: origin, destinationKey: destinationKey)
        guard let entry = distances[key]?.distance(for: mode) else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > freshnessTTL { return nil }
        return entry
    }

    func fresh(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        fresh(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    /// Cached entry regardless of TTL — for "best we have so far" display
    /// while a fresh fetch is in flight.
    func anyCached(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        let key = Self.bucketKey(origin: origin, destinationKey: destinationKey)
        return distances[key]?.distance(for: mode)
    }

    func anyCached(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        anyCached(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func isInflight(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> Bool {
        inflight.contains(Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode))
    }

    func isInflight(origin: (lat: Double, lon: Double), stationId: Int) -> Bool {
        isInflight(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func markInflight(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) {
        inflight.insert(Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode))
    }

    func markInflight(origin: (lat: Double, lon: Double), stationId: Int) {
        markInflight(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func clearInflight(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) {
        inflight.remove(Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode))
    }

    func clearInflight(origin: (lat: Double, lon: Double), stationId: Int) {
        clearInflight(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func isInNegativeCache(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> Bool {
        let key = Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode)
        guard let savedAt = failures[key] else { return false }
        return Date().timeIntervalSince(savedAt) < negativeCacheTTL
    }

    func isInNegativeCache(origin: (lat: Double, lon: Double), stationId: Int) -> Bool {
        isInNegativeCache(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func record(
        meters: Double,
        expectedTravelTime: TimeInterval,
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) {
        let key = Self.bucketKey(origin: origin, destinationKey: destinationKey)
        let distance = WalkingDistance(
            meters: meters,
            expectedTravelTime: expectedTravelTime,
            cachedAt: Date()
        )
        var entry = distances[key] ?? AccessRouteDistances()
        entry.set(distance, for: mode)
        distances[key] = entry
        failures[Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode)] = nil
        persistDebounced()
    }

    func record(
        meters: Double,
        expectedTravelTime: TimeInterval,
        origin: (lat: Double, lon: Double),
        stationId: Int
    ) {
        record(
            meters: meters,
            expectedTravelTime: expectedTravelTime,
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    func recordFailure(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) {
        let key = Self.requestKey(origin: origin, destinationKey: destinationKey, mode: mode)
        failures[key] = Date()
    }

    func recordFailure(origin: (lat: Double, lon: Double), stationId: Int) {
        recordFailure(
            origin: origin,
            destinationKey: Self.stationDestinationKey(stationId: stationId),
            mode: .walking
        )
    }

    /// Wipe the cache. Used by Settings -> "Clear access route cache."
    func clearAll() {
        loadTask?.cancel()
        loadTask = nil
        hasLoadedFromDisk = true
        shouldDiscardHydratedDistances = true
        distances.removeAll()
        failures.removeAll()
        persistDebounced()
    }

    /// Mark every entry stale by backdating its timestamp. `fresh` then
    /// returns nil for everything, which triggers refetch — but `anyCached`
    /// still has the old data to fall back on while MapKit responds.
    func invalidateAll() {
        shouldInvalidateHydratedDistances = true
        let stamp = Date.distantPast
        distances = distances.mapValues { $0.invalidated(at: stamp) }
        persistDebounced()
    }

    /// H3 cells we currently have entries for. The background-refresh path
    /// uses this to know which (origin-cell, station) pairs the user
    /// actually cares about — we only re-query those, not the entire
    /// 145-station catalog.
    func cachedBuckets() -> Set<String> {
        var buckets: Set<String> = []
        for key in distances.keys {
            // Key format is "{h3CellID}_{destinationKey}". The cell ID never
            // contains an underscore, so splitting on the first underscore
            // is unambiguous.
            if let underscoreIdx = key.firstIndex(of: "_") {
                buckets.insert(String(key[..<underscoreIdx]))
            }
        }
        return buckets
    }

    /// Number of stored entries (for surfacing in Settings UI).
    var entryCount: Int { distances.count }

    // MARK: - Persistence

    private struct Persisted: Codable, Sendable {
        let version: Int
        let distances: [String: AccessRouteDistances]
    }

    private struct LegacyPersisted: Codable, Sendable {
        let version: Int
        let distances: [String: WalkingDistance]
    }

    nonisolated private static func loadPersistedDistances(from fileURL: URL) -> [String: AccessRouteDistances] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let decoded = try? JSONDecoder().decode(Persisted.self, from: data),
           decoded.version == 2 {
            return decoded.distances
        }
        if let legacy = try? JSONDecoder().decode(LegacyPersisted.self, from: data),
           legacy.version == 1 {
            return legacy.distances.mapValues {
                AccessRouteDistances(walking: $0, cycling: nil)
            }
        }
        return [:]
    }

    private func persistDebounced() {
        persistTask?.cancel()
        let snapshot = Persisted(version: 2, distances: distances)
        let url = fileURL
        persistTask = Task.detached(priority: .utility) {
            // Debounce burst writes during a refresh cycle so we don't
            // re-encode and rewrite the file once per station.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func requestKey(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> String {
        "\(mode.rawValue)_\(bucketKey(origin: origin, destinationKey: destinationKey))"
    }
}
