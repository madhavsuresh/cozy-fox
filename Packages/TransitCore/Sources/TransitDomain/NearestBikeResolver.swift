import Foundation
import TransitModels

/// Given a current location, available stations, and optional per-bike data,
/// pick nearby Divvy station options and free-floating e-bike options.
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
        picks(
            top: 1,
            from: origin,
            stations: stations,
            eBikes: eBikes,
            includeFreeFloating: includeFreeFloating,
            now: now
        ).first
    }

    public func nearby(
        topStations: Int,
        topFreeFloating: Int,
        from origin: (lat: Double, lon: Double),
        stations: [BikeStation],
        eBikes: [EBike],
        includeFreeFloating: Bool,
        now: Date = .now
    ) -> NearbyBikeResults {
        NearbyBikeResults(
            stationPicks: picks(
                top: topStations,
                from: origin,
                stations: stations,
                eBikes: eBikes,
                includeFreeFloating: false,
                now: now
            ),
            freeFloatingPicks: includeFreeFloating
                ? freeFloatingPicks(
                    top: topFreeFloating,
                    from: origin,
                    eBikes: eBikes,
                    now: now
                )
                : []
        )
    }

    /// Returns up to `top` nearest stations (by walking distance) that each have
    /// at least one usable e-bike. Sorted ascending by distance. Used by the
    /// dashboard's "Closest e-bikes" list.
    public func picks(
        top: Int,
        from origin: (lat: Double, lon: Double),
        stations: [BikeStation],
        eBikes: [EBike],
        includeFreeFloating: Bool,
        now: Date = .now
    ) -> [NearestBikePick] {
        guard top > 0 else { return [] }

        let dockedBikesByStation = Dictionary(grouping: usableBikes(from: eBikes).filter { !$0.isFreeFloating }) {
            $0.stationId ?? ""
        }

        let candidates: [Candidate] = stations.compactMap { station in
            let distance = Distance.meters(
                from: origin,
                to: (station.latitude, station.longitude)
            )
            guard distance <= maxStationDistanceMeters else { return nil }

            let stationCount = station.eBikesAvailable
            guard stationCount > 0 else { return nil }

            let dockedBikes = (dockedBikesByStation[station.id] ?? [])
                .sorted { $0.currentRangeMeters > $1.currentRangeMeters }

            let bestRange = max(
                station.eBikesAvailable > 0 ? minimumUsableRangeMeters : 0,
                dockedBikes.map(\.currentRangeMeters).max() ?? 0
            )

            return Candidate(
                station: station,
                walkingDistance: distance,
                bestRange: bestRange,
                dockedBikes: dockedBikes,
                stationCount: stationCount
            )
        }

        return candidates.sorted(by: <).prefix(top).map { winner in
            NearestBikePick(
                station: winner.station,
                walkingDistanceMeters: winner.walkingDistance,
                bestRangeMeters: winner.bestRange,
                dockedBikes: winner.dockedBikes,
                freeFloatingNearby: 0,
                nearbyFreeFloatingBikes: [],
                computedAt: now
            )
        }
    }

    public func freeFloatingPicks(
        top: Int,
        from origin: (lat: Double, lon: Double),
        eBikes: [EBike],
        now: Date = .now
    ) -> [NearestFreeBikePick] {
        guard top > 0 else { return [] }

        return usableBikes(from: eBikes)
            .filter(\.isFreeFloating)
            .compactMap { bike -> FreeBikeCandidate? in
                let distance = Distance.meters(
                    from: origin,
                    to: (bike.latitude, bike.longitude)
                )
                guard distance <= maxStationDistanceMeters else { return nil }
                return FreeBikeCandidate(bike: bike, walkingDistance: distance)
            }
            .sorted(by: <)
            .prefix(top)
            .map {
                NearestFreeBikePick(
                    bike: $0.bike,
                    walkingDistanceMeters: $0.walkingDistance,
                    computedAt: now
                )
            }
    }

    private func usableBikes(from eBikes: [EBike]) -> [EBike] {
        eBikes.filter {
            !$0.isReserved
                && !$0.isDisabled
                && $0.currentRangeMeters >= minimumUsableRangeMeters
        }
    }
}

public struct NearbyBikeResults: Sendable, Hashable {
    public let stationPicks: [NearestBikePick]
    public let freeFloatingPicks: [NearestFreeBikePick]

    public init(
        stationPicks: [NearestBikePick],
        freeFloatingPicks: [NearestFreeBikePick]
    ) {
        self.stationPicks = stationPicks
        self.freeFloatingPicks = freeFloatingPicks
    }
}

private struct Candidate: Comparable {
    let station: BikeStation
    let walkingDistance: Double
    let bestRange: Double
    let dockedBikes: [EBike]
    let stationCount: Int

    // Strictly nearest first. Tie-breaker prefers stations with more bikes
    // so two equidistant stations with very different inventory don't flap.
    static func < (lhs: Candidate, rhs: Candidate) -> Bool {
        if lhs.walkingDistance != rhs.walkingDistance {
            return lhs.walkingDistance < rhs.walkingDistance
        }
        return lhs.stationCount > rhs.stationCount
    }
}

private struct FreeBikeCandidate: Comparable {
    let bike: EBike
    let walkingDistance: Double

    static func < (lhs: FreeBikeCandidate, rhs: FreeBikeCandidate) -> Bool {
        if lhs.walkingDistance != rhs.walkingDistance {
            return lhs.walkingDistance < rhs.walkingDistance
        }
        return lhs.bike.currentRangeMeters > rhs.bike.currentRangeMeters
    }
}
