import Foundation
import TransitModels

/// Ranks nearby rail stations by practical access from the user's current
/// point. MapKit walking routes are useful but occasionally over-route around
/// downtown blocks and bridges, so this keeps a directness proxy in the mix.
public struct StationAccessRanker: Sendable {
    public struct AccessCandidate<Item: Sendable>: Sendable {
        public let item: Item
        public let directDistanceMeters: Double
        public let walkingDistanceMeters: Double?
        public let walkingTravelTime: TimeInterval?

        public init(
            item: Item,
            directDistanceMeters: Double,
            walkingDistanceMeters: Double? = nil,
            walkingTravelTime: TimeInterval? = nil
        ) {
            self.item = item
            self.directDistanceMeters = directDistanceMeters
            self.walkingDistanceMeters = walkingDistanceMeters
            self.walkingTravelTime = walkingTravelTime
        }
    }

    public struct RankedAccessCandidate<Item: Sendable>: Sendable {
        public let item: Item
        public let directDistanceMeters: Double
        public let walkingDistanceMeters: Double?
        public let accessDistanceMeters: Double
        public let displayTravelTime: TimeInterval
        public let isApproximateTravelTime: Bool
    }

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

    /// Minimum size of the initial candidate cluster before we trust a
    /// rolling standard-deviation break.
    public let minimumClusterCount: Int
    /// If the next candidate sits this many standard deviations above the
    /// rolling prefix mean, treat it as outside the close cluster.
    public let clusterBreakStandardDeviations: Double
    /// Keeps tiny variance among the first few stops from making a normal city
    /// block look like an outlier.
    public let minimumClusterStandardDeviationMeters: Double
    /// Absolute guardrail for smooth downtown stop sequences where every
    /// station is only a little farther than the previous one. Candidates
    /// beyond this spread are not "nearby choices" even without one big gap.
    public let maximumClusterAccessSpreadMeters: Double
    public let routeDirectnessMultiplier: Double
    public let routeNoiseAllowanceMeters: Double
    public let walkingMetersPerSecond: Double

    public init(
        minimumClusterCount: Int = 4,
        clusterBreakStandardDeviations: Double = 2.0,
        minimumClusterStandardDeviationMeters: Double = 75,
        maximumClusterAccessSpreadMeters: Double = 1_000,
        routeDirectnessMultiplier: Double = 1.35,
        routeNoiseAllowanceMeters: Double = 300,
        walkingMetersPerSecond: Double = 1.34
    ) {
        self.minimumClusterCount = minimumClusterCount
        self.clusterBreakStandardDeviations = clusterBreakStandardDeviations
        self.minimumClusterStandardDeviationMeters = minimumClusterStandardDeviationMeters
        self.maximumClusterAccessSpreadMeters = maximumClusterAccessSpreadMeters
        self.routeDirectnessMultiplier = routeDirectnessMultiplier
        self.routeNoiseAllowanceMeters = routeNoiseAllowanceMeters
        self.walkingMetersPerSecond = walkingMetersPerSecond
    }

    public func rank(_ candidates: [Candidate]) -> [RankedCandidate] {
        rank(candidates.map { candidate in
            AccessCandidate(
                item: candidate.station,
                directDistanceMeters: candidate.directDistanceMeters,
                walkingDistanceMeters: candidate.walkingDistanceMeters,
                walkingTravelTime: candidate.walkingTravelTime
            )
        })
        .map { candidate in
            RankedCandidate(
                station: candidate.item,
                directDistanceMeters: candidate.directDistanceMeters,
                walkingDistanceMeters: candidate.walkingDistanceMeters,
                accessDistanceMeters: candidate.accessDistanceMeters,
                displayTravelTime: candidate.displayTravelTime,
                isApproximateTravelTime: candidate.isApproximateTravelTime
            )
        }
    }

    public func rank<Item: Sendable>(
        _ candidates: [AccessCandidate<Item>]
    ) -> [RankedAccessCandidate<Item>] {
        candidates
            .map(rankedAccessCandidate)
            .sorted { lhs, rhs in
                if abs(lhs.accessDistanceMeters - rhs.accessDistanceMeters) > 1 {
                    return lhs.accessDistanceMeters < rhs.accessDistanceMeters
                }
                return lhs.directDistanceMeters < rhs.directDistanceMeters
            }
    }

    public func visibleCandidates(from ranked: [RankedCandidate]) -> [RankedCandidate] {
        visibleAccessCandidates(from: ranked.map { candidate in
            RankedAccessCandidate(
                item: candidate.station,
                directDistanceMeters: candidate.directDistanceMeters,
                walkingDistanceMeters: candidate.walkingDistanceMeters,
                accessDistanceMeters: candidate.accessDistanceMeters,
                displayTravelTime: candidate.displayTravelTime,
                isApproximateTravelTime: candidate.isApproximateTravelTime
            )
        })
        .map { candidate in
            RankedCandidate(
                station: candidate.item,
                directDistanceMeters: candidate.directDistanceMeters,
                walkingDistanceMeters: candidate.walkingDistanceMeters,
                accessDistanceMeters: candidate.accessDistanceMeters,
                displayTravelTime: candidate.displayTravelTime,
                isApproximateTravelTime: candidate.isApproximateTravelTime
            )
        }
    }

    public func visibleAccessCandidates<Item: Sendable>(
        from ranked: [RankedAccessCandidate<Item>]
    ) -> [RankedAccessCandidate<Item>] {
        guard !ranked.isEmpty else { return [] }
        let distances = ranked.map(\.accessDistanceMeters)
        let cutoff = min(
            clusterCutoffIndex(for: distances),
            spreadCutoffIndex(for: distances)
        )
        return Array(ranked.prefix(cutoff))
    }

    private func rankedAccessCandidate<Item: Sendable>(
        _ candidate: AccessCandidate<Item>
    ) -> RankedAccessCandidate<Item> {
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

        return RankedAccessCandidate(
            item: candidate.item,
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

    private func clusterCutoffIndex(for distances: [Double]) -> Int {
        guard distances.count > minimumClusterCount else { return distances.count }
        for index in minimumClusterCount..<distances.count {
            let prefix = distances[..<index]
            let mean = prefix.reduce(0, +) / Double(prefix.count)
            let variance = prefix.reduce(0) { partial, value in
                let delta = value - mean
                return partial + delta * delta
            } / Double(prefix.count)
            let standardDeviation = max(
                sqrt(variance),
                minimumClusterStandardDeviationMeters
            )
            let candidate = distances[index]
            let zScore = (candidate - mean) / standardDeviation
            if zScore >= clusterBreakStandardDeviations {
                return index
            }
        }
        return distances.count
    }

    private func spreadCutoffIndex(for distances: [Double]) -> Int {
        guard let best = distances.first else { return 0 }
        let limit = best + maximumClusterAccessSpreadMeters
        return distances.firstIndex { $0 > limit } ?? distances.count
    }
}
