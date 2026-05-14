import Foundation
import Observation
import SwiftyH3

struct WalkingDistance: Codable, Equatable, Sendable {
    let meters: Double
    let expectedTravelTime: TimeInterval
    let cachedAt: Date
}

/// Persistent cache of MapKit walking-distance lookups, keyed on a ~50m
/// origin grid + station id. Lives on the main actor and is `@Observable`
/// so SwiftUI re-renders when MapKit results land. Persists to a JSON file
/// in `Caches/` — small enough that we just rewrite the whole file on
/// change (debounced).
@MainActor
@Observable
final class WalkingDistanceStore {
    private(set) var distances: [String: WalkingDistance] = [:]

    @ObservationIgnored
    private var inflight: Set<String> = []

    @ObservationIgnored
    private var failures: [String: Date] = [:]

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

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
        load()
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

    static func bucketKey(origin: (lat: Double, lon: Double), stationId: Int) -> String {
        let cellID: String
        if let cell = try? H3LatLng(
            latitudeDegs: origin.lat,
            longitudeDegs: origin.lon
        ).cell(at: cellResolution) {
            cellID = String(cell.id)
        } else {
            cellID = "raw-\(origin.lat)-\(origin.lon)"
        }
        return "\(cellID)_\(stationId)"
    }

    /// Fresh entry, or nil if missing or past TTL.
    func fresh(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        let key = Self.bucketKey(origin: origin, stationId: stationId)
        guard let entry = distances[key] else { return nil }
        if Date().timeIntervalSince(entry.cachedAt) > freshnessTTL { return nil }
        return entry
    }

    /// Cached entry regardless of TTL — for "best we have so far" display
    /// while a fresh fetch is in flight.
    func anyCached(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        let key = Self.bucketKey(origin: origin, stationId: stationId)
        return distances[key]
    }

    func isInflight(origin: (lat: Double, lon: Double), stationId: Int) -> Bool {
        inflight.contains(Self.bucketKey(origin: origin, stationId: stationId))
    }

    func markInflight(origin: (lat: Double, lon: Double), stationId: Int) {
        inflight.insert(Self.bucketKey(origin: origin, stationId: stationId))
    }

    func clearInflight(origin: (lat: Double, lon: Double), stationId: Int) {
        inflight.remove(Self.bucketKey(origin: origin, stationId: stationId))
    }

    func isInNegativeCache(origin: (lat: Double, lon: Double), stationId: Int) -> Bool {
        let key = Self.bucketKey(origin: origin, stationId: stationId)
        guard let savedAt = failures[key] else { return false }
        return Date().timeIntervalSince(savedAt) < negativeCacheTTL
    }

    func record(
        meters: Double,
        expectedTravelTime: TimeInterval,
        origin: (lat: Double, lon: Double),
        stationId: Int
    ) {
        let key = Self.bucketKey(origin: origin, stationId: stationId)
        distances[key] = WalkingDistance(
            meters: meters,
            expectedTravelTime: expectedTravelTime,
            cachedAt: Date()
        )
        failures[key] = nil
        persistDebounced()
    }

    func recordFailure(origin: (lat: Double, lon: Double), stationId: Int) {
        let key = Self.bucketKey(origin: origin, stationId: stationId)
        failures[key] = Date()
    }

    /// Wipe the cache. Used by Settings → "Clear walking distance cache."
    func clearAll() {
        distances.removeAll()
        failures.removeAll()
        persistDebounced()
    }

    /// Mark every entry stale by backdating its timestamp. `fresh` then
    /// returns nil for everything, which triggers refetch — but `anyCached`
    /// still has the old data to fall back on while MapKit responds.
    func invalidateAll() {
        let stamp = Date.distantPast
        distances = distances.mapValues {
            WalkingDistance(
                meters: $0.meters,
                expectedTravelTime: $0.expectedTravelTime,
                cachedAt: stamp
            )
        }
        persistDebounced()
    }

    /// H3 cells we currently have entries for. The background-refresh path
    /// uses this to know which (origin-cell, station) pairs the user
    /// actually cares about — we only re-query those, not the entire
    /// 145-station catalog.
    func cachedBuckets() -> Set<String> {
        var buckets: Set<String> = []
        for key in distances.keys {
            // Key format is "{h3CellID}_{stationId}". The cell ID never
            // contains an underscore, so splitting on the last underscore
            // is unambiguous.
            if let underscoreIdx = key.lastIndex(of: "_") {
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
        let distances: [String: WalkingDistance]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data),
              decoded.version == 1
        else { return }
        distances = decoded.distances
    }

    private func persistDebounced() {
        persistTask?.cancel()
        let snapshot = Persisted(version: 1, distances: distances)
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
}
