import Foundation

/// Adds a flat walking-cost penalty when the straight-line path from origin
/// to destination crosses the Chicago River. Haversine distance treats the
/// river as invisible, but pedestrians must detour to a bridge, which in
/// downtown means crossing the Loop's south-of-river bridges from
/// Streeterville/River North or vice versa. The penalty is large enough to
/// flip ranking when two stops are within a couple hundred meters of each
/// other on opposite sides of the river, without dominating cases where the
/// south-of-river stop is genuinely much closer.
public enum RiverPenalty {
    /// Meters added once if the straight line crosses the river polylines.
    /// Multiple intersections aren't double-counted: the goal is to model
    /// "you have to find a bridge," not to compound penalties on weird
    /// paths.
    public static let crossingMeters: Double = 500

    /// Polylines approximating the Chicago River downtown. Each entry is a
    /// sequence of (lat, lon) vertices; consecutive vertices form segments.
    /// Coverage is biased toward where the river matters for L stop
    /// surfacing — the main branch and the lower portions of the north and
    /// south branches.
    static let polylines: [[(lat: Double, lon: Double)]] = [
        // Main branch: Lake Michigan inlet → Wolf Point.
        [
            (41.8893, -87.6097),
            (41.8886, -87.6180),
            (41.8884, -87.6280),
            (41.8884, -87.6340),
            (41.8884, -87.6390),
        ],
        // North branch: Wolf Point → north past Goose Island.
        [
            (41.8884, -87.6390),
            (41.8940, -87.6440),
            (41.9000, -87.6478),
            (41.9080, -87.6510),
            (41.9170, -87.6535),
            (41.9280, -87.6570),
            (41.9380, -87.6620),
            (41.9450, -87.6680),
        ],
        // South branch: Wolf Point → curving SE toward Chinatown.
        [
            (41.8884, -87.6390),
            (41.8800, -87.6390),
            (41.8720, -87.6395),
            (41.8640, -87.6400),
            (41.8570, -87.6395),
            (41.8510, -87.6375),
        ],
    ]

    /// Returns the penalty (in meters) to add to a Haversine distance from
    /// `origin` to `destination`. Zero if the straight line stays on one
    /// side of every river segment; `crossingMeters` if it crosses any.
    public static func penalty(
        from origin: (lat: Double, lon: Double),
        to destination: (lat: Double, lon: Double)
    ) -> Double {
        crosses(from: origin, to: destination) ? crossingMeters : 0
    }

    static func crosses(
        from origin: (lat: Double, lon: Double),
        to destination: (lat: Double, lon: Double)
    ) -> Bool {
        for polyline in polylines {
            for i in 0..<(polyline.count - 1) {
                if intersects(origin, destination, polyline[i], polyline[i + 1]) {
                    return true
                }
            }
        }
        return false
    }

    /// Standard 2D segment intersection via CCW orientation tests. Treats
    /// lat/lon as Cartesian — fine for crossing-or-not at city scale, since
    /// the sign of the cross product is invariant to the longitude
    /// distortion at a fixed latitude band.
    private static func intersects(
        _ a: (lat: Double, lon: Double),
        _ b: (lat: Double, lon: Double),
        _ c: (lat: Double, lon: Double),
        _ d: (lat: Double, lon: Double)
    ) -> Bool {
        func orient(
            _ p: (lat: Double, lon: Double),
            _ q: (lat: Double, lon: Double),
            _ r: (lat: Double, lon: Double)
        ) -> Double {
            (q.lat - p.lat) * (r.lon - p.lon) - (q.lon - p.lon) * (r.lat - p.lat)
        }
        let o1 = orient(a, b, c)
        let o2 = orient(a, b, d)
        let o3 = orient(c, d, a)
        let o4 = orient(c, d, b)
        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
    }
}
