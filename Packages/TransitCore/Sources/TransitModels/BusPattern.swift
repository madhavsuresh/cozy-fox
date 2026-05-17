import Foundation

/// One CTA bus route variant — the ordered set of (lat, lon, along-pattern
/// distance) points that a vehicle on this pattern travels. Sourced from
/// `getpatterns`. A single route normally has 2–6 patterns (one per
/// direction × time-of-day variant + detour variants).
///
/// Phase 3 uses this for:
///   - replacing haversine "DUE-but-far" with along-pattern remaining
///     distance — much more accurate than crow-fly because buses follow
///     real streets,
///   - detecting "vehicle already crossed the stop" abstain,
///   - eventually, geometry ETA from `(stop_pdist - vehicle.pdist) / speed`.
public struct BusPattern: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let route: String
    public let directionName: String
    /// Pattern length in feet. Useful when interpreting `pdist`s near loops
    /// or terminals.
    public let lengthFeet: Double?
    /// Detour ID that produced this pattern, when this is a detour variant
    /// rather than the regular pattern. Surfaced for phase 3b's
    /// stop-removed-by-detour logic; phase 3 itself only reads patterns
    /// where `detourId == nil`.
    public let detourId: String?
    public let points: [BusPatternPoint]

    public init(
        id: Int,
        route: String,
        directionName: String,
        lengthFeet: Double?,
        detourId: String?,
        points: [BusPatternPoint]
    ) {
        self.id = id
        self.route = route
        self.directionName = directionName
        self.lengthFeet = lengthFeet
        self.detourId = detourId
        self.points = points
    }

    /// Along-pattern distance (feet) of the stop with `stopId`, if it's part
    /// of this pattern. nil when the pattern doesn't serve this stop —
    /// caller decides whether to fall back to haversine.
    public func patternDistanceForStop(_ stopId: Int) -> Double? {
        points.first { $0.stopId == stopId }?.patternDistanceFeet
    }
}

/// A single point along a `BusPattern`. Points come in two flavors: stop
/// points (`stopId != nil`) and waypoint points (geometry-only).
public struct BusPatternPoint: Codable, Sendable, Hashable {
    public let sequence: Int
    public let latitude: Double
    public let longitude: Double
    /// Along-pattern distance in feet, accumulating from the start of the
    /// pattern. CTA calls this `pdist`.
    public let patternDistanceFeet: Double
    /// "S" for stop points, "W" for waypoints, sometimes nil/unknown.
    public let kindRaw: String?
    public let stopId: Int?
    public let stopName: String?

    public init(
        sequence: Int,
        latitude: Double,
        longitude: Double,
        patternDistanceFeet: Double,
        kindRaw: String?,
        stopId: Int?,
        stopName: String?
    ) {
        self.sequence = sequence
        self.latitude = latitude
        self.longitude = longitude
        self.patternDistanceFeet = patternDistanceFeet
        self.kindRaw = kindRaw
        self.stopId = stopId
        self.stopName = stopName
    }

    public var isStop: Bool { stopId != nil }
}
