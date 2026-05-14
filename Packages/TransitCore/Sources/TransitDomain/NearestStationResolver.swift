import Foundation
import TransitModels

/// Picks the nearest CTA "L" stations to a given coordinate from the
/// `LStationCatalog`. Used by the refresh coordinator as a fallback when
/// the user has no tracked train preferences yet, so the dashboard surfaces
/// "what's coming up at the closest station" out of the box.
///
/// Ranking uses **effective distance**: Haversine plus a penalty when the
/// straight line crosses the Chicago River. Two stops at similar Haversine
/// distance but on opposite sides of the river have very different
/// walking costs, and this nudges the river-side that matches the user's
/// side without us needing real pedestrian routing. The returned tuple
/// reports Haversine for display so chip distances don't include the
/// invisible bridge cost.
public struct NearestStationResolver: Sendable {
    public let maxDistanceMeters: Double
    public let appliesRiverPenalty: Bool

    public init(
        maxDistanceMeters: Double = 5_000,
        appliesRiverPenalty: Bool = true
    ) {
        self.maxDistanceMeters = maxDistanceMeters
        self.appliesRiverPenalty = appliesRiverPenalty
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

    /// Top N closest stations serving a specific line, sorted by effective
    /// distance. Used so the user can pick a specific stop after pinning a
    /// line. The reported distance is Haversine.
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
                rank(station: station, from: origin)
            }
            .filter { $0.effective <= maxDistanceMeters }
            .sorted { $0.effective < $1.effective }
            .prefix(limit)
            .map { (station: $0.station, distance: $0.haversine) }
    }

    /// Returns every station within `radiusMeters` of effective distance,
    /// sorted ascending by effective distance. Reported `distance` is
    /// Haversine. Used for the dashboard "Near you" cluster view — callers
    /// can rely on the ordering to pick the closest serving stop per line
    /// without re-comparing.
    public func all(
        within radiusMeters: Double,
        of origin: (lat: Double, lon: Double),
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = []
    ) -> [(station: LStation, distance: Double)] {
        catalog
            .filter { !excludingStationIds.contains($0.id) }
            .map { station in
                rank(station: station, from: origin)
            }
            .filter { $0.effective <= radiusMeters }
            .sorted { $0.effective < $1.effective }
            .map { (station: $0.station, distance: $0.haversine) }
    }

    private func rank(
        station: LStation,
        from origin: (lat: Double, lon: Double)
    ) -> (station: LStation, haversine: Double, effective: Double) {
        let destination = (lat: station.latitude, lon: station.longitude)
        let haversine = Distance.meters(from: origin, to: destination)
        let penalty = appliesRiverPenalty
            ? RiverPenalty.penalty(from: origin, to: destination)
            : 0
        return (station, haversine, haversine + penalty)
    }
}
