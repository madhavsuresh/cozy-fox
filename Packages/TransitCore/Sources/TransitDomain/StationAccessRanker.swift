import Foundation
import TransitModels

/// Ranks nearby rail stations by practical access from the user's current
/// point. MapKit walking routes are useful but occasionally over-route around
/// downtown blocks and bridges, so this keeps a directness proxy in the mix.
public struct StationAccessRanker: Sendable {
    public struct Candidate: Sendable {
        public let station: LStation
        public let directDistanceMeters: Double
        public let walkingDistanceMeters: Double?
        public let walkingTravelTime: TimeInterval?

        public init(
            station: LStation,
            directDistanceMeters: Double,
            walkingDistanceMeters: Double? = nil,
            walkingTravelTime: TimeInterval? = nil
        ) {
            self.station = station
            self.directDistanceMeters = directDistanceMeters
            self.walkingDistanceMeters = walkingDistanceMeters
            self.walkingTravelTime = walkingTravelTime
        }
    }

    public struct RankedCandidate: Sendable {
        public let station: LStation
        public let directDistanceMeters: Double
        public let walkingDistanceMeters: Double?
        public let accessDistanceMeters: Double
        public let displayTravelTime: TimeInterval
        public let isApproximateTravelTime: Bool
    }

    /// About half a mile. In dense downtown station choice, this is close
    /// enough that route noise, river crossings, and personal preference can
    /// reasonably flip the best stop.
    public let visibleDirectDeltaMeters: Double
    public let visibleAccessDeltaMeters: Double
    public let baseVisibleCount: Int
    public let routeDirectnessMultiplier: Double
    public let routeNoiseAllowanceMeters: Double
    public let walkingMetersPerSecond: Double

    public init(
        visibleDirectDeltaMeters: Double = 800,
        visibleAccessDeltaMeters: Double = 650,
        baseVisibleCount: Int = 3,
        routeDirectnessMultiplier: Double = 1.35,
        routeNoiseAllowanceMeters: Double = 300,
        walkingMetersPerSecond: Double = 1.34
    ) {
        self.visibleDirectDeltaMeters = visibleDirectDeltaMeters
        self.visibleAccessDeltaMeters = visibleAccessDeltaMeters
        self.baseVisibleCount = baseVisibleCount
        self.routeDirectnessMultiplier = routeDirectnessMultiplier
        self.routeNoiseAllowanceMeters = routeNoiseAllowanceMeters
        self.walkingMetersPerSecond = walkingMetersPerSecond
    }

    public func rank(_ candidates: [Candidate]) -> [RankedCandidate] {
        candidates
            .map(rankedCandidate)
            .sorted { lhs, rhs in
                if abs(lhs.accessDistanceMeters - rhs.accessDistanceMeters) > 1 {
                    return lhs.accessDistanceMeters < rhs.accessDistanceMeters
                }
                return lhs.directDistanceMeters < rhs.directDistanceMeters
            }
    }

    public func visibleCandidates(
        from ranked: [RankedCandidate],
        pinnedStationId: Int? = nil
    ) -> [RankedCandidate] {
        guard let first = ranked.first else { return [] }
        let bestAccess = first.accessDistanceMeters
        let bestDirect = ranked.map(\.directDistanceMeters).min() ?? first.directDistanceMeters

        return ranked.enumerated().compactMap { index, entry in
            if index < baseVisibleCount { return entry }
            if pinnedStationId == entry.station.id { return entry }
            if entry.accessDistanceMeters <= bestAccess + visibleAccessDeltaMeters {
                return entry
            }
            if entry.directDistanceMeters <= bestDirect + visibleDirectDeltaMeters {
                return entry
            }
            return nil
        }
    }

    private func rankedCandidate(_ candidate: Candidate) -> RankedCandidate {
        let proxyDistance = directnessProxyDistance(for: candidate.directDistanceMeters)
        let cappedProxyDistance = proxyDistance + routeNoiseAllowanceMeters
        let accessDistance = min(candidate.walkingDistanceMeters ?? proxyDistance, cappedProxyDistance)
        let displayTime: TimeInterval
        let isApproximate: Bool

        if let walkingTravelTime = candidate.walkingTravelTime,
           let walkingDistance = candidate.walkingDistanceMeters,
           walkingDistance <= cappedProxyDistance
        {
            displayTime = walkingTravelTime
            isApproximate = false
        } else {
            displayTime = accessDistance / walkingMetersPerSecond
            isApproximate = true
        }

        return RankedCandidate(
            station: candidate.station,
            directDistanceMeters: candidate.directDistanceMeters,
            walkingDistanceMeters: candidate.walkingDistanceMeters,
            accessDistanceMeters: accessDistance,
            displayTravelTime: displayTime,
            isApproximateTravelTime: isApproximate
        )
    }

    private func directnessProxyDistance(for directDistanceMeters: Double) -> Double {
        directDistanceMeters * routeDirectnessMultiplier
    }
}
