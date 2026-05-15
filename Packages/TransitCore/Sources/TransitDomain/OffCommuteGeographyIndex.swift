import Foundation
import TransitModels

/// Spatial index of "places the user goes when they're NOT commuting."
/// Built from `MobilityProfile.routeObservations` whose `direction`
/// doesn't match the user's current commute direction (e.g. weekend
/// trips, evening errands), bucketed into coarse ~500 m grid cells.
///
/// Pure value type. The output is a `Set<Cell>` that a delight scorer
/// can intersect with a candidate route's polyline (cell-stamped) to
/// answer "how much of this alternative passes through neighborhoods
/// the user has chosen to be in?"
///
/// Resolution choice: ~500 m matches a "you know this neighborhood"
/// granularity. Tighter (100 m) would inflate the index size and
/// over-fit to specific addresses; coarser (1 km) makes Logan Square
/// and Bucktown indistinguishable, which defeats the point.
public struct OffCommuteGeographyIndex: Sendable, Hashable {
    public struct Cell: Hashable, Sendable, Codable {
        public let latBucket: Int
        public let lonBucket: Int

        public init(latBucket: Int, lonBucket: Int) {
            self.latBucket = latBucket
            self.lonBucket = lonBucket
        }

        /// Reverse: midpoint of the cell. Handy for tests and
        /// diagnostics; not used in the hot path.
        public func midpoint(scale: Double = 200) -> (lat: Double, lon: Double) {
            (lat: (Double(latBucket) + 0.5) / scale,
             lon: (Double(lonBucket) + 0.5) / scale)
        }

        /// Quantize a (lat, lon) into a `Cell` at the given scale.
        /// `scale = 200` ≈ 500 m grid cells; `200 = 1/0.005` and
        /// 0.005° latitude ≈ 555 m.
        public static func from(
            latitude: Double,
            longitude: Double,
            scale: Double = 200
        ) -> Cell {
            Cell(
                latBucket: Int((latitude * scale).rounded(.down)),
                lonBucket: Int((longitude * scale).rounded(.down))
            )
        }
    }

    public let cells: Set<Cell>

    public init(cells: Set<Cell>) {
        self.cells = cells
    }

    /// Build from a profile's route observations. Cells come from each
    /// observation's `origin` and `destination` coords. Filter rules:
    /// - Skip observations whose direction matches `currentCommute`
    ///   (those are commute trips, not free-time exploration).
    /// - Skip observations older than `withinDays` (default 90).
    ///   Older trips might be stale interests.
    public static func build(
        from observations: [MobilityProfile.RouteObservation],
        currentCommute: CommuteDirection,
        withinDays: Int = 90,
        now: Date = .now,
        scale: Double = 200
    ) -> OffCommuteGeographyIndex {
        let cutoff = now.addingTimeInterval(-Double(withinDays) * 86_400)
        var cells: Set<Cell> = []
        for observation in observations {
            guard observation.recordedAt >= cutoff else { continue }
            guard observation.direction != currentCommute else { continue }
            if let origin = observation.origin {
                cells.insert(Cell.from(
                    latitude: origin.latitude,
                    longitude: origin.longitude,
                    scale: scale
                ))
            }
            if let destination = observation.destination {
                cells.insert(Cell.from(
                    latitude: destination.latitude,
                    longitude: destination.longitude,
                    scale: scale
                ))
            }
        }
        return OffCommuteGeographyIndex(cells: cells)
    }

    /// 0.0–1.0 delight score for a route described by a polyline of
    /// (lat, lon) waypoints. Quantizes each waypoint to a cell and
    /// counts how many of those cells appear in `self.cells`.
    /// Returns 0 when the polyline has fewer than 2 points (no path)
    /// or when the index is empty.
    public func delightScore(
        forPolyline waypoints: [(lat: Double, lon: Double)],
        scale: Double = 200
    ) -> Double {
        guard waypoints.count >= 2, !cells.isEmpty else { return 0 }
        let polylineCells: Set<Cell> = Set(waypoints.map {
            Cell.from(latitude: $0.lat, longitude: $0.lon, scale: scale)
        })
        let overlap = polylineCells.intersection(cells).count
        return Double(overlap) / Double(polylineCells.count)
    }
}
