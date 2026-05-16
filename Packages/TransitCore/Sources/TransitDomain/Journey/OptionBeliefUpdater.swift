import Foundation
import TransitModels

public struct OptionBeliefUpdater: Sendable {
    public let proximityScaleMeters: Double
    public let movementBoostScale: Double

    public init(
        proximityScaleMeters: Double = 500,
        movementBoostScale: Double = 0.6
    ) {
        self.proximityScaleMeters = max(1, proximityScaleMeters)
        self.movementBoostScale = max(0, min(1, movementBoostScale))
    }

    /// Update option beliefs given a user position. Closer to an option's
    /// boarding point → higher posterior weight on that option. Returns a
    /// normalized distribution; sum is 1.0 when at least one option has
    /// non-zero weight. Falls back to a uniform prior over the option set
    /// when no inputs can be evaluated.
    public func update(
        currentBeliefs: [UUID: Double],
        userPosition: PlannerCoordinate?,
        options: [JourneyOption]
    ) -> [UUID: Double] {
        guard !options.isEmpty else { return [:] }

        let optionIDs = Set(options.map(\.id))
        let priors: [UUID: Double] = options.reduce(into: [:]) { acc, option in
            acc[option.id] = currentBeliefs[option.id] ?? (1.0 / Double(options.count))
        }

        guard let userPosition else {
            return priors  // already a valid normalized prior
        }

        var posteriors: [UUID: Double] = [:]
        for option in options {
            let prior = priors[option.id] ?? 0
            let boardingPoint = firstBoardingPoint(of: option)?.coordinate
            let proximityLikelihood: Double
            if let boardingPoint {
                let distance = haversineMeters(
                    from: (userPosition.latitude, userPosition.longitude),
                    to: (boardingPoint.latitude, boardingPoint.longitude)
                )
                proximityLikelihood = exp(-distance / proximityScaleMeters)
            } else {
                proximityLikelihood = 0.5
            }
            posteriors[option.id] = prior * proximityLikelihood
        }

        let total = posteriors.values.reduce(0, +)
        guard total > 0 else { return priors }
        let normalized = posteriors.mapValues { $0 / total }
        return normalized.filter { optionIDs.contains($0.key) }
    }

    private func firstBoardingPoint(of option: JourneyOption) -> JourneyPoint? {
        for slot in option.slots {
            switch slot {
            case .fixed(let leg):
                return leg.toPoint
            case .exchangeable(let alternatives, _):
                if let first = alternatives.first { return first.toPoint }
            }
        }
        return nil
    }
}
