import Foundation
import TransitModels

/// Geometry helpers for CTA bus patterns. Pure functions over `BusPattern`
/// and `VehiclePosition`. Mirrors `geometry.py` from the cta-tight-arrivals
/// prototype — same map-match-by-segment-projection idea — but with the
/// detour-original-point handling left to a later phase.
public enum BusPatternGeometry {
    /// Result of projecting a (lat, lon) onto the closest pattern segment.
    public struct MapMatch: Sendable, Hashable {
        public enum Quality: String, Sendable, Hashable {
            /// Within 50 m of the pattern. Strong evidence the vehicle is
            /// genuinely on this pattern.
            case high
            /// Within 100 m. Probably on-pattern; treat as confirming.
            case medium
            /// Within 200 m. Plausible but not strong.
            case low
            /// >200 m or pattern is unusable. Treat as off-pattern.
            case unusable
        }

        public let projectedPatternDistanceFeet: Double
        public let crossTrackMeters: Double
        public let quality: Quality
    }

    /// Project `(lat, lon)` onto `pattern` and return the closest segment's
    /// along-pattern distance plus a cross-track quality flag. Pure
    /// haversine + local planar projection — no CoreLocation dependency.
    public static func mapMatch(_ pattern: BusPattern, lat: Double, lon: Double) -> MapMatch? {
        guard pattern.points.count >= 2 else { return nil }

        var bestDistanceMeters = Double.infinity
        var bestProjectedPdist: Double = 0
        for i in 0..<(pattern.points.count - 1) {
            let a = pattern.points[i]
            let b = pattern.points[i + 1]
            let projection = projectPointToSegment(
                lat: lat, lon: lon,
                lat1: a.latitude, lon1: a.longitude,
                lat2: b.latitude, lon2: b.longitude
            )
            if projection.distanceMeters < bestDistanceMeters {
                bestDistanceMeters = projection.distanceMeters
                let segmentLengthFeet = b.patternDistanceFeet - a.patternDistanceFeet
                bestProjectedPdist = a.patternDistanceFeet + projection.fraction * segmentLengthFeet
            }
        }

        let quality: MapMatch.Quality = {
            switch bestDistanceMeters {
            case ..<50: return .high
            case ..<100: return .medium
            case ..<200: return .low
            default: return .unusable
            }
        }()

        return MapMatch(
            projectedPatternDistanceFeet: bestProjectedPdist,
            crossTrackMeters: bestDistanceMeters,
            quality: quality
        )
    }

    /// Returns the pattern that matches a vehicle's reported `pid` exactly.
    /// When `pid` is provided but no cached pattern carries that id, returns
    /// nil — the caller should treat this as a pattern miss rather than
    /// reinterpret the vehicle's `pdist` against a different pattern (which
    /// would silently translate distance to the wrong coordinate frame).
    ///
    /// When `pid` is nil (the vehicle's pid is missing from the feed),
    /// falls back to the first non-detour pattern matching route + direction
    /// so callers can still get geometry — the pdist they read is
    /// "directionally useful" rather than precise.
    public static func pattern(
        for vehiclePatternId: Int?,
        route: String,
        directionName: String?,
        in patterns: [BusPattern]
    ) -> BusPattern? {
        if let pid = vehiclePatternId {
            return patterns.first { $0.id == pid }
        }
        let routeMatches = patterns.filter { $0.route.caseInsensitiveCompare(route) == .orderedSame }
        if let directionName {
            let directional = routeMatches.first {
                $0.directionName.caseInsensitiveCompare(directionName) == .orderedSame
                    && $0.detourId == nil
            }
            if let directional { return directional }
        }
        return routeMatches.first { $0.detourId == nil } ?? routeMatches.first
    }

    /// Remaining along-pattern distance from the vehicle to the stop, in
    /// feet. Negative when the vehicle is *past* the stop on this pattern.
    /// nil when either the vehicle's pdist or the stop's pdist on this
    /// pattern is unknown.
    public static func remainingFeetAlongPattern(
        vehiclePatternDistance: Double?,
        stopId: Int,
        pattern: BusPattern
    ) -> Double? {
        guard let vehiclePatternDistance,
              let stopPdist = pattern.patternDistanceForStop(stopId)
        else { return nil }
        return stopPdist - vehiclePatternDistance
    }

    // MARK: - Internal

    private struct SegmentProjection {
        let fraction: Double
        let distanceMeters: Double
    }

    /// Project a point onto a great-circle segment in a small local planar
    /// frame. Picks a reference centroid so distortion stays well under a
    /// foot at city scales — buses don't span continents.
    private static func projectPointToSegment(
        lat: Double, lon: Double,
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> SegmentProjection {
        let refLat = (lat1 + lat2 + lat) / 3
        let refLon = (lon1 + lon2 + lon) / 3
        let earthRadiusMeters = 6_371_008.8
        let cosRef = cos(refLat * .pi / 180)

        func xy(_ pLat: Double, _ pLon: Double) -> (x: Double, y: Double) {
            let x = (pLon - refLon) * .pi / 180 * earthRadiusMeters * cosRef
            let y = (pLat - refLat) * .pi / 180 * earthRadiusMeters
            return (x, y)
        }

        let p = xy(lat, lon)
        let a = xy(lat1, lon1)
        let b = xy(lat2, lon2)
        let vx = b.x - a.x
        let vy = b.y - a.y
        let denom = vx * vx + vy * vy

        guard denom > 1e-9 else {
            let dx = p.x - a.x
            let dy = p.y - a.y
            return SegmentProjection(fraction: 0, distanceMeters: (dx * dx + dy * dy).squareRoot())
        }

        let raw = ((p.x - a.x) * vx + (p.y - a.y) * vy) / denom
        let t = min(max(raw, 0), 1)
        let qx = a.x + t * vx
        let qy = a.y + t * vy
        let dx = p.x - qx
        let dy = p.y - qy
        return SegmentProjection(fraction: t, distanceMeters: (dx * dx + dy * dy).squareRoot())
    }
}
