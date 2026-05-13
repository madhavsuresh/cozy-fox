import Foundation
import TransitModels

/// Picks the nearest CTA "L" stations to a given coordinate from the
/// `LStationCatalog`. Used by the refresh coordinator as a fallback when
/// the user has no tracked train preferences yet, so the dashboard surfaces
/// "what's coming up at the closest station" out of the box.
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
        all(within: maxDistanceMeters, of: origin, catalog: catalog)
            .filter { !excludingStationIds.contains($0.station.id) }
            .prefix(limit)
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

    /// Top N closest stations serving a specific line, sorted by distance.
    /// Used so the user can pick a specific stop after pinning a line.
    public func closestStations(
        onLine line: LineColor,
        to origin: (lat: Double, lon: Double),
        limit: Int = 3,
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = []
    ) -> [(station: LStation, distance: Double)] {
        catalog
            .filter { !excludingStationIds.contains($0.id) }
            .filter { $0.servedLines.contains(line) }
            .map { station in
                (
                    station: station,
                    distance: Distance.meters(
                        from: origin,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxDistanceMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { (station: $0.station, distance: $0.distance) }
    }

    /// Returns every station within `radiusMeters`, sorted by distance.
    /// Used for the dashboard "Near you" cluster view.
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
}
