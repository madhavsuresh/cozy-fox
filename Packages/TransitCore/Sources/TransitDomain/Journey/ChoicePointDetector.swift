import Foundation
import TransitModels

public struct ChoicePointDetector: Sendable {
    public let proximityRadiusMeters: Double

    public init(proximityRadiusMeters: Double = 1_500) {
        self.proximityRadiusMeters = max(0, proximityRadiusMeters)
    }

    public func detect(
        in option: JourneyOption,
        userPosition: PlannerCoordinate? = nil,
        now: Date = .now
    ) -> [ChoicePoint] {
        var points: [ChoicePoint] = []
        for slot in option.slots {
            guard case .exchangeable(let alternatives, let policyHint) = slot, !alternatives.isEmpty else {
                continue
            }
            let firstAlt = alternatives.first!
            let title = alternatives.map(\.displayLabel).joined(separator: " or ")
            let location = firstAlt.fromPoint.coordinate

            let confidence: Double
            if let userPosition, let location {
                let distance = haversineMeters(
                    from: (userPosition.latitude, userPosition.longitude),
                    to: (location.latitude, location.longitude)
                )
                confidence = distance > proximityRadiusMeters ? 0.4 : 0.8
            } else {
                confidence = 0.5
            }

            points.append(
                ChoicePoint(
                    title: title,
                    location: location,
                    decisionByTime: nil,
                    candidateIDs: alternatives.map(\.id),
                    recommendedCandidateID: alternatives.first?.id,
                    recommendationReason: policyHint,
                    confidence: confidence
                )
            )
        }
        return points
    }
}

func haversineMeters(from origin: (lat: Double, lon: Double), to dest: (lat: Double, lon: Double)) -> Double {
    let R: Double = 6_371_000
    let lat1 = origin.lat * .pi / 180
    let lat2 = dest.lat * .pi / 180
    let dLat = (dest.lat - origin.lat) * .pi / 180
    let dLon = (dest.lon - origin.lon) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * atan2(sqrt(a), sqrt(1 - a))
}
