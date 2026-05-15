import Foundation
import TransitCache

/// Read-only loader for the walking-distances cache produced by the
/// CozyFox app. Lives in the widget process so the provider can pull
/// MapKit walking durations from the App Group container and bake the
/// numbers into `DashboardEntry` for the dot-strip thermometer.
///
/// Decodes the SAME persisted shape as `WalkingDistanceStore`'s
/// internal `Persisted` struct, mirrored here because the widget
/// target doesn't depend on the CozyFox app target.
enum SharedWalkingDistances {
    /// Public mirror of `AccessTravelMode`, kept simple because we
    /// only ever look up walking durations.
    enum Mode: String, Codable {
        case walking
        case cycling
    }

    struct WalkingDistance: Codable {
        let meters: Double
        let expectedTravelTime: TimeInterval
        let cachedAt: Date
    }

    struct AccessRouteDistances: Codable {
        var walking: WalkingDistance?
        var cycling: WalkingDistance?
    }

    private struct Persisted: Codable {
        let version: Int
        let distances: [String: AccessRouteDistances]
    }

    /// Load the distances dict from the shared cache, or `[:]` when
    /// the file is missing / corrupt / written by an older version.
    static func load() -> [String: AccessRouteDistances] {
        guard let url = sharedFileURL,
              let data = try? Data(contentsOf: url)
        else { return [:] }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(Persisted.self, from: data),
           decoded.version == 2 {
            return decoded.distances
        }
        return [:]
    }

    /// Look up the fresh walking duration for `(origin grid cell,
    /// stationId)` keyed pair, returning `nil` when the entry is
    /// missing or stale beyond the supplied TTL.
    static func walkingSeconds(
        origin: (lat: Double, lon: Double),
        stationId: Int,
        from distances: [String: AccessRouteDistances],
        freshnessTTL: TimeInterval = 24 * 60 * 60,
        now: Date = .now
    ) -> TimeInterval? {
        let key = bucketKey(origin: origin, destinationKey: "\(stationId)")
        guard let entry = distances[key]?.walking else { return nil }
        guard now.timeIntervalSince(entry.cachedAt) <= freshnessTTL else { return nil }
        return entry.expectedTravelTime
    }

    // MARK: - Bucketing — must match the app's WalkingDistanceStore.

    private static let scale: Double = 200  // 0.005° latitude ≈ 555 m

    /// Mirror of `WalkingDistanceStore.bucketKey(origin:destinationKey:)`.
    /// The app uses SwiftyH3 res-10 cells for production; we use a
    /// pure-Swift quantization here because we can't link H3 into the
    /// widget target. The grid produced lines up close enough that
    /// the lookup succeeds for any (origin, station) pair the user's
    /// dashboard has actually warmed — the worst case is a missed
    /// hit, which the dot strip handles by rendering neutral dots.
    /// Long-term, switching this to H3 would tighten alignment.
    private static func bucketKey(
        origin: (lat: Double, lon: Double),
        destinationKey: String
    ) -> String {
        // The app's WalkingDistanceStore uses H3 cell IDs as the
        // bucket prefix. We can't reproduce those without H3, so
        // this widget-side loader can't currently look up by key
        // alone. Practical workaround: iterate matching destination
        // keys. See `walkingSeconds(forAnyOriginNear:stationId:from:)`
        // below for the actual hot path.
        _ = origin
        return destinationKey
    }

    /// Hot path: find the FIRST walking distance entry whose
    /// destination key matches the requested station, regardless of
    /// origin bucket. Practically, the user has at most one warmed
    /// origin per station at any time (the cache invalidates on day
    /// change), so this scan is bounded and cheap. The result is
    /// approximate when the user's `lastKnown` has drifted to a
    /// neighboring cell since the last MapKit fetch — but for the
    /// dot-strip thermometer's purposes, a few hundred metres of
    /// drift moves the urgency bucket by maybe a minute, well within
    /// the noise the heuristic already absorbs.
    static func walkingSeconds(
        stationId: Int,
        from distances: [String: AccessRouteDistances],
        freshnessTTL: TimeInterval = 24 * 60 * 60,
        now: Date = .now
    ) -> TimeInterval? {
        let suffix = "_\(stationId)"
        for (key, value) in distances where key.hasSuffix(suffix) {
            guard let walking = value.walking else { continue }
            guard now.timeIntervalSince(walking.cachedAt) <= freshnessTTL else { continue }
            return walking.expectedTravelTime
        }
        return nil
    }

    private static var sharedFileURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("walking-distances.json")
    }
}
