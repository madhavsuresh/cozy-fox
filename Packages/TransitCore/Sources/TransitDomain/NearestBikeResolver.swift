import Foundation
import TransitModels

/// Given a current location, available stations, and (optionally) free-floating
/// e-bikes, pick the **nearest Divvy station that actually has an e-bike** —
/// either docked at the station or floating within walking distance of it.
///
/// Selection is pure distance once the "has an e-bike" filter is applied. The
/// older scoring (range-penalty + scarcity-penalty) sometimes promoted a
/// farther but better-stocked station over a closer one with a single bike,
/// which contradicted what the dashboard's "Closest e-bike" label promises.
public struct NearestBikeResolver: Sendable {
    public let maxStationDistanceMeters: Double
    public let freeFloatingPickRadiusMeters: Double
    public let minimumUsableRangeMeters: Double

    public init(
        maxStationDistanceMeters: Double = 1_500,
        freeFloatingPickRadiusMeters: Double = 200,
        minimumUsableRangeMeters: Double = 3_000
    ) {
        self.maxStationDistanceMeters = maxStationDistanceMeters
        self.freeFloatingPickRadiusMeters = freeFloatingPickRadiusMeters
        self.minimumUsableRangeMeters = minimumUsableRangeMeters
    }

    public func pick(
        from origin: (lat: Double, lon: Double),
        stations: [BikeStation],
        eBikes: [EBike],
        includeFreeFloating: Bool,
        now: Date = .now
    ) -> NearestBikePick? {
        let usableBikes = eBikes.filter { !$0.isReserved && !$0.isDisabled
            && $0.currentRangeMeters >= minimumUsableRangeMeters }

        let candidates: [Candidate] = stations.compactMap { station in
            let distance = Distance.meters(
                from: origin,
                to: (station.latitude, station.longitude)
            )
            guard distance <= maxStationDistanceMeters else { return nil }

            // Free-floating e-bikes near this station (irrespective of station_id).
            let nearby = usableBikes.filter { bike in
                Distance.meters(
                    from: (bike.latitude, bike.longitude),
                    to: (station.latitude, station.longitude)
                ) <= freeFloatingPickRadiusMeters
            }

            let stationCount = station.eBikesAvailable
            let totalAvailable = stationCount + (includeFreeFloating ? nearby.count : 0)
            guard totalAvailable > 0 else { return nil }

            let bestRange = max(
                station.eBikesAvailable > 0 ? minimumUsableRangeMeters : 0,
                nearby.map(\.currentRangeMeters).max() ?? 0
            )

            return Candidate(
                station: station,
                walkingDistance: distance,
                bestRange: bestRange,
                freeFloating: nearby.count,
                stationCount: stationCount
            )
        }

        guard let winner = candidates.min(by: <) else { return nil }
        return NearestBikePick(
            station: winner.station,
            walkingDistanceMeters: winner.walkingDistance,
            bestRangeMeters: winner.bestRange,
            freeFloatingNearby: winner.freeFloating,
            computedAt: now
        )
    }
}

private struct Candidate: Comparable {
    let station: BikeStation
    let walkingDistance: Double
    let bestRange: Double
    let freeFloating: Int
    let stationCount: Int

    // Strictly nearest first. Tie-breaker prefers stations with more bikes
    // so two equidistant stations with very different inventory don't flap.
    static func < (lhs: Candidate, rhs: Candidate) -> Bool {
        if lhs.walkingDistance != rhs.walkingDistance {
            return lhs.walkingDistance < rhs.walkingDistance
        }
        return (lhs.stationCount + lhs.freeFloating) > (rhs.stationCount + rhs.freeFloating)
    }
}
