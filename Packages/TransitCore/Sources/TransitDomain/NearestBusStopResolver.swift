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
        var bestByRoute: [String: (stop: BusStop, distance: Double)] = [:]
        for stop in catalog {
            let distance = Distance.meters(
                from: origin,
                to: (stop.latitude, stop.longitude)
            )
            guard distance <= maxDistanceMeters else { continue }
            if bestByRoute[stop.route].map({ distance < $0.distance }) ?? true {
                bestByRoute[stop.route] = (stop, distance)
            }
        }
        return bestByRoute.values
            .sorted { $0.distance < $1.distance }
            .prefix(max(0, limit))
            .map(\.stop)
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
        // When the caller passes the default 14k-row catalog, fall back to
        // the precomputed `byRoute` index instead of scanning every stop.
        let candidates: [BusStop] = catalog.count == BusStopCatalog.all.count
            ? BusStopCatalog.stops(onRoute: route)
            : catalog
        var best: (stop: BusStop, distance: Double)?
        for stop in candidates where stop.route == route {
            let distance = Distance.meters(from: origin, to: (stop.latitude, stop.longitude))
            guard distance <= maxDistanceMeters else { continue }
            if best.map({ distance < $0.distance }) ?? true {
                best = (stop, distance)
            }
        }
        return best?.stop
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
        nearestStopsPerDirection(
            onRoute: route,
            to: origin,
            limitPerDirection: 1,
            catalog: catalog
        )
        .map(\.stop)
    }

    /// For a pinned route, returns the closest stops in each dominant
    /// direction, with up to `limitPerDirection` stops per direction. This
    /// lets the UI show both adjacent stops when the user is between them.
    public func nearestStopsPerDirection(
        onRoute route: String,
        to origin: (lat: Double, lon: Double),
        limitPerDirection: Int = 2,
        catalog: [BusStop]
    ) -> [(stop: BusStop, distance: Double)] {
        // Same shortcut as `nearest(onRoute:to:catalog:)` — skip the 14k-row
        // scan when the caller hasn't filtered the catalog.
        let candidates: [BusStop] = catalog.count == BusStopCatalog.all.count
            ? BusStopCatalog.stops(onRoute: route)
            : catalog
        var byDirection: [String: [BusStop]] = [:]
        for stop in candidates where stop.route == route {
            byDirection[stop.directionLabel, default: []].append(stop)
        }

        // Drop directions that are stop-count outliers — they're typically
        // single-stop turnarounds at the route's terminus, not real legs.
        let maxStops = byDirection.values.map(\.count).max() ?? 0
        let threshold = max(3, maxStops / 2)
        let dominant = byDirection.filter { $0.value.count >= threshold }

        return dominant
            .flatMap { (_, stops) -> [(BusStop, Double)] in
                Array(stops
                    .map { ($0, Distance.meters(from: origin, to: ($0.latitude, $0.longitude))) }
                    .filter { $0.1 <= maxDistanceMeters }
                    .sorted { $0.1 < $1.1 }
                    .prefix(max(1, limitPerDirection)))
            }
            .sorted { $0.1 < $1.1 }
            .map { (stop: $0.0, distance: $0.1) }
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
