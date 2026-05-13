import Foundation
import TransitModels

/// Picks the nearest CTA bus stops from a `BusStop` catalog. The catalog
/// typically contains one entry per (physical stop × route) pair, so the same
/// physical corner can appear multiple times with different routes — that's
/// intentional so the refresh path can call the CTA Bus Tracker API with the
/// specific (route, stopId) tuple it needs.
public struct NearestBusStopResolver: Sendable {
    public let maxDistanceMeters: Double

    public init(maxDistanceMeters: Double = 1_500) {
        self.maxDistanceMeters = maxDistanceMeters
    }

    /// Returns the nearest stops, deduplicated by route — i.e., one stop per
    /// distinct route, picking the closest occurrence. So with `limit: 3` you
    /// get 3 *different* routes (each at its closest stop) rather than the 3
    /// closest physical stops which might all be on the same corner.
    public func nearest(
        to origin: (lat: Double, lon: Double),
        limit: Int = 3,
        catalog: [BusStop]
    ) -> [BusStop] {
        let ranked = catalog
            .map { stop in
                (
                    stop: stop,
                    distance: Distance.meters(
                        from: origin,
                        to: (stop.latitude, stop.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxDistanceMeters }
            .sorted { $0.distance < $1.distance }

        var seenRoutes: Set<String> = []
        var result: [BusStop] = []
        for (stop, _) in ranked {
            if !seenRoutes.contains(stop.route) {
                seenRoutes.insert(stop.route)
                result.append(stop)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// Closest stop on a specific route — used when the user pins a bus route
    /// and wants "the next #22 at the closest stop." Returns nil if no stop on
    /// that route is within `maxDistanceMeters`. The catalog has multiple
    /// entries per physical stop (one per direction); we just pick the
    /// nearest, regardless of direction.
    public func nearest(
        onRoute route: String,
        to origin: (lat: Double, lon: Double),
        catalog: [BusStop]
    ) -> BusStop? {
        catalog
            .filter { $0.route == route }
            .map { stop in
                (stop, Distance.meters(from: origin, to: (stop.latitude, stop.longitude)))
            }
            .filter { $0.1 <= maxDistanceMeters }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// For a pinned route, the closest stop in each *dominant* direction.
    ///
    /// We only consider a direction "dominant" if it has at least half as many
    /// stops as the busiest direction on this route. That filters out terminus
    /// anomalies — e.g., route 65 (east-west) has one "Northbound" stop at
    /// the Navy Pier loop where buses turn; treating that as a third
    /// direction would surface a misleading "→ Northbound" row.
    ///
    /// Result is sorted by distance (closest dominant direction first).
    public func nearestPerDirection(
        onRoute route: String,
        to origin: (lat: Double, lon: Double),
        catalog: [BusStop]
    ) -> [BusStop] {
        let onRoute = catalog.filter { $0.route == route }
        let byDirection = Dictionary(grouping: onRoute, by: \.directionLabel)

        // Drop directions that are stop-count outliers — they're typically
        // single-stop turnarounds at the route's terminus, not real legs.
        let maxStops = byDirection.values.map(\.count).max() ?? 0
        let threshold = max(3, maxStops / 2)
        let dominant = byDirection.filter { $0.value.count >= threshold }

        return dominant
            .compactMap { (_, stops) -> (BusStop, Double)? in
                stops
                    .map { ($0, Distance.meters(from: origin, to: ($0.latitude, $0.longitude))) }
                    .filter { $0.1 <= maxDistanceMeters }
                    .min { $0.1 < $1.1 }
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Returns all stops within the radius, sorted by distance. Useful for
    /// the dashboard "Near you" cluster view that wants raw proximity, not
    /// route-dedup'd picks.
    public func all(
        within radiusMeters: Double,
        of origin: (lat: Double, lon: Double),
        catalog: [BusStop]
    ) -> [(stop: BusStop, distance: Double)] {
        catalog
            .map { stop in
                (
                    stop: stop,
                    distance: Distance.meters(
                        from: origin,
                        to: (stop.latitude, stop.longitude)
                    )
                )
            }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
    }
}
