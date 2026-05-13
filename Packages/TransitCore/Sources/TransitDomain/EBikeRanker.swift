import Foundation
import TransitModels

/// Ranks a list of free-floating e-bikes around a point. Used in the detail
/// screen when the user wants to see every available e-bike nearby.
public struct RankedEBike: Sendable, Hashable, Identifiable {
    public let bike: EBike
    public let distanceMeters: Double
    public var id: String { bike.id }
}

public struct EBikeRanker: Sendable {
    public init() {}

    public func rank(
        bikes: [EBike],
        from origin: (lat: Double, lon: Double),
        within radiusMeters: Double = 600,
        topK: Int = 12
    ) -> [RankedEBike] {
        bikes
            .lazy
            .filter { !$0.isReserved && !$0.isDisabled }
            .map { bike -> RankedEBike in
                let d = Distance.meters(
                    from: origin,
                    to: (bike.latitude, bike.longitude)
                )
                return RankedEBike(bike: bike, distanceMeters: d)
            }
            .filter { $0.distanceMeters <= radiusMeters }
            .sorted { lhs, rhs in
                let lScore = lhs.distanceMeters - 0.05 * lhs.bike.currentRangeMeters
                let rScore = rhs.distanceMeters - 0.05 * rhs.bike.currentRangeMeters
                return lScore < rScore
            }
            .prefix(topK)
            .map { $0 }
    }
}
