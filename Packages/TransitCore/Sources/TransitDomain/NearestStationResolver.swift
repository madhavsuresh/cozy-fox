import Foundation
import TransitModels

/// Picks the nearest CTA "L" stations to a given coordinate from the
/// `LStationCatalog`. Ranks by Haversine distance — the dashboard layers a
/// MapKit walking-distance refinement on top of this, so we don't bother
/// modeling pedestrian barriers here.
public struct NearestStationResolver: Sendable {
    public let maxDistanceMeters: Double

    public init(maxDistanceMeters: Double = 5_000) {
        self.maxDistanceMeters = maxDistanceMeters
    }

    public func nearest(
        to origin: (lat: Double, lon: Double),
        limit: Int = 2,
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = []
    ) -> [LStation] {
        boundedNearest(
            within: maxDistanceMeters,
            of: origin,
            limit: limit,
            catalog: catalog,
            excludingStationIds: excludingStationIds,
            matches: { _ in true }
        )
        .map(\.station)
    }

    /// The single closest station that serves a specific line — used when the
    /// user pins a line and wants "the next Blue Line at the nearest stop."
    /// Returns nil if no station on that line is within `maxDistanceMeters`.
    public func nearest(
        onLine line: LineColor,
        to origin: (lat: Double, lon: Double),
        catalog: [LStation] = LStationCatalog.all
    ) -> LStation? {
        closestStations(onLine: line, to: origin, limit: 1, catalog: catalog).first?.station
    }

    /// Top N closest stations serving a specific line, sorted by Haversine
    /// distance.
    public func closestStations(
        onLine line: LineColor,
        to origin: (lat: Double, lon: Double),
        limit: Int = 3,
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = []
    ) -> [(station: LStation, distance: Double)] {
        // Skip the line-membership predicate when the caller passes the
        // default catalog — the precomputed by-line index avoids a full
        // 145-row scan.
        if catalog.count == LStationCatalog.all.count {
            return boundedNearest(
                within: maxDistanceMeters,
                of: origin,
                limit: limit,
                catalog: LStationCatalog.stations(onLine: line),
                excludingStationIds: excludingStationIds,
                matches: { _ in true }
            )
        }
        return boundedNearest(
            within: maxDistanceMeters,
            of: origin,
            limit: limit,
            catalog: catalog,
            excludingStationIds: excludingStationIds,
            matches: { $0.servedLines.contains(line) }
        )
    }

    /// Returns every station within `radiusMeters`, sorted by Haversine
    /// distance ascending. Used for the dashboard "Near you" cluster view.
    public func all(
        within radiusMeters: Double,
        of origin: (lat: Double, lon: Double),
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = []
    ) -> [(station: LStation, distance: Double)] {
        catalog
            .filter { !excludingStationIds.contains($0.id) }
            .map { station in
                (
                    station: station,
                    distance: Distance.meters(
                        from: origin,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }
    }

    private func boundedNearest(
        within radiusMeters: Double,
        of origin: (lat: Double, lon: Double),
        limit: Int,
        catalog: [LStation],
        excludingStationIds: Set<Int>,
        matches: (LStation) -> Bool
    ) -> [(station: LStation, distance: Double)] {
        guard limit > 0 else { return [] }
        var best: [(station: LStation, distance: Double)] = []
        best.reserveCapacity(limit)
        for station in catalog where !excludingStationIds.contains(station.id) && matches(station) {
            let distance = Distance.meters(
                from: origin,
                to: (station.latitude, station.longitude)
            )
            guard distance <= radiusMeters else { continue }
            let entry = (station: station, distance: distance)
            let index = best.firstIndex { entry.distance < $0.distance } ?? best.endIndex
            if index < best.endIndex {
                best.insert(entry, at: index)
            } else if best.count < limit {
                best.append(entry)
            }
            if best.count > limit {
                best.removeLast()
            }
        }
        return best
    }
}
