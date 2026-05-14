import Foundation
import TransitModels

struct TripHistoryRanker: Sendable {
    let profile: MobilityProfile
    let origin: PlannerCoordinate
    let destination: PlannerCoordinate
    let now: Date
    let calendar: Calendar

    init(
        profile: MobilityProfile,
        origin: PlannerCoordinate,
        destination: PlannerCoordinate,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.profile = profile
        self.origin = origin
        self.destination = destination
        self.now = now
        self.calendar = calendar
    }

    func rankPlans(
        _ plans: [TripPlan],
        fallbackPriority: (TripPlan) -> Int = { _ in 0 }
    ) -> [TripPlan] {
        plans.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = score(plan: lhs.element)
                let rhsScore = score(plan: rhs.element)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                let lhsPriority = fallbackPriority(lhs.element)
                let rhsPriority = fallbackPriority(rhs.element)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func score(plan: TripPlan) -> Double {
        score(resolutions: plan.legs.compactMap(\.transit?.resolution))
    }

    func score(resolutions: [TransitResolution]) -> Double {
        var seen: Set<String> = []
        return resolutions.reduce(0) { total, resolution in
            guard seen.insert(routeKey(resolution)).inserted else { return total }
            return total + score(resolution: resolution)
        }
    }

    func score(resolution: TransitResolution) -> Double {
        profile.routeObservations
            .compactMap { observationScore($0, for: resolution) }
            .sorted(by: >)
            .prefix(8)
            .reduce(0, +)
    }

    private func observationScore(
        _ observation: MobilityProfile.RouteObservation,
        for resolution: TransitResolution
    ) -> Double? {
        guard matches(observation, resolution: resolution) else { return nil }

        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let ageDays = max(0, now.timeIntervalSince(observation.recordedAt) / 86_400)

        let recency = max(0, 4 - ageDays / 14)
        let weekdayBoost = observation.weekday == weekday ? 1.5 : 0
        let hourBoost = max(0, 2 - Double(hourDistance(hour, observation.hour)) * 0.5)
        let originBoost = proximityBoost(
            observation.origin,
            target: origin,
            nearbyBoost: 3,
            broadBoost: 1
        )
        let destinationBoost = proximityBoost(
            observation.destination,
            target: destination,
            nearbyBoost: 5,
            broadBoost: 1.5
        )

        return 1 + recency + weekdayBoost + hourBoost + originBoost + destinationBoost
    }

    private func matches(
        _ observation: MobilityProfile.RouteObservation,
        resolution: TransitResolution
    ) -> Bool {
        switch resolution {
        case .line(let line):
            return observation.line == line
        case .bus(let route):
            return observation.busRoute == route
        case .metra(let route):
            return observation.metraRoute == route
        case .unknown:
            return false
        }
    }

    private func proximityBoost(
        _ location: MobilityProfile.RouteLocation?,
        target: PlannerCoordinate,
        nearbyBoost: Double,
        broadBoost: Double
    ) -> Double {
        guard let location else { return 0 }
        let meters = Distance.meters(
            from: (location.latitude, location.longitude),
            to: (target.latitude, target.longitude)
        )
        if meters <= 800 { return nearbyBoost }
        if meters <= 3_000 { return broadBoost }
        return 0
    }

    private func routeKey(_ resolution: TransitResolution) -> String {
        switch resolution {
        case .line(let line):
            return "line:\(line.rawValue)"
        case .bus(let route):
            return "bus:\(route)"
        case .metra(let route):
            return "metra:\(route)"
        case .unknown(let raw):
            return "unknown:\(raw)"
        }
    }

    private func hourDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let raw = abs(lhs - rhs)
        return min(raw, 24 - raw)
    }
}
