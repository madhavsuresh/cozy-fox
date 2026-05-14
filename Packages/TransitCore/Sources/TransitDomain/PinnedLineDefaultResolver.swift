import Foundation
import TransitModels

/// Picks the first direction shown after the user pins a line, using the same
/// local-only route history that powers commute prediction.
public struct PinnedLineDefaultResolver: Sendable {
    public let clock: Clock

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    public func preferredTrainDestination(
        line: LineColor,
        availableDestinations: [String],
        preferences: UserRoutePreferences,
        profile: MobilityProfile,
        context: CommuteContext,
        location: LastKnownLocation?
    ) -> String? {
        let summaryLabels = profile.summary.routePatterns.values
            .filter { $0.mode == .train && $0.routeId == line.rawValue }
            .flatMap { pattern -> [(label: String, count: Int)] in
                pattern.directionLabelCounts.map { ($0.key, $0.value) }
            }
        return preferredLabel(
            availableLabels: availableDestinations,
            preferenceLabels: preferences.trains
                .filter { $0.line == line }
                .map { ($0.directionLabel, $0.direction) },
            observationLabels: profile.routeObservations.compactMap { observation in
                guard observation.line == line,
                      let destination = observation.trainDestination,
                      !destination.isEmpty
                else { return nil }
                return (destination, observation)
            },
            summaryLabels: summaryLabels,
            context: context,
            location: location
        )
    }

    public func preferredBusDirection(
        route: String,
        availableDirections: [String],
        preferences: UserRoutePreferences,
        profile: MobilityProfile,
        context: CommuteContext,
        location: LastKnownLocation?
    ) -> String? {
        let summaryLabels = profile.summary.routePatterns.values
            .filter { $0.mode == .bus && $0.routeId == route }
            .flatMap { pattern -> [(label: String, count: Int)] in
                pattern.directionLabelCounts.map { ($0.key, $0.value) }
            }
        return preferredLabel(
            availableLabels: availableDirections,
            preferenceLabels: preferences.buses
                .filter { $0.route == route }
                .map { ($0.directionLabel, $0.direction) },
            observationLabels: profile.routeObservations.compactMap { observation in
                guard observation.busRoute == route,
                      let direction = observation.busDirection,
                      !direction.isEmpty
                else { return nil }
                return (direction, observation)
            },
            summaryLabels: summaryLabels,
            context: context,
            location: location
        )
    }

    private func preferredLabel(
        availableLabels: [String],
        preferenceLabels: [(label: String, direction: CommuteDirection)],
        observationLabels: [(label: String, observation: MobilityProfile.RouteObservation)],
        summaryLabels: [(label: String, count: Int)],
        context: CommuteContext,
        location: LastKnownLocation?
    ) -> String? {
        let available = availableLabels.filter { !$0.isEmpty }
        guard !available.isEmpty else { return nil }
        let preferredDirection = CommutePlanner(clock: clock).preferredDirection(context: context)
        var scores: [String: Double] = [:]
        var latest: [String: Date] = [:]

        for preference in preferenceLabels where !preference.label.isEmpty {
            scores[preference.label, default: 0] += 40 + directionBoost(
                preference.direction,
                preferred: preferredDirection
            )
        }

        for entry in observationLabels {
            scores[entry.label, default: 0] += observationScore(
                entry.observation,
                preferredDirection: preferredDirection,
                location: location
            )
            latest[entry.label] = max(latest[entry.label] ?? .distantPast, entry.observation.recordedAt)
        }

        // Summary labels fold in only when we already have *some* signal for
        // them or to break ties — they shouldn't override a recent raw pin.
        for entry in summaryLabels where !entry.label.isEmpty {
            scores[entry.label, default: 0] += summaryScore(count: entry.count)
        }

        let ranked = scores.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            let lhsLatest = latest[lhs.key] ?? .distantPast
            let rhsLatest = latest[rhs.key] ?? .distantPast
            if lhsLatest != rhsLatest { return lhsLatest > rhsLatest }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }

        for candidate in ranked {
            if let match = match(candidate.key, in: available) {
                return match
            }
        }

        return available.first
    }

    private func summaryScore(count: Int) -> Double {
        guard count > 0 else { return 0 }
        return 2 + log(Double(count) + 1) * 1.5
    }

    private func match(_ candidate: String, in availableLabels: [String]) -> String? {
        if let exact = availableLabels.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            return exact
        }
        let normalizedCandidate = normalize(candidate)
        return availableLabels.first { normalize($0) == normalizedCandidate }
            ?? availableLabels.first { normalize($0).contains(normalizedCandidate) }
            ?? availableLabels.first { normalizedCandidate.contains(normalize($0)) }
    }

    private func normalize(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func observationScore(
        _ observation: MobilityProfile.RouteObservation,
        preferredDirection: CommuteDirection,
        location: LastKnownLocation?
    ) -> Double {
        let weekday = clock.calendar.component(.weekday, from: clock.now)
        let hour = clock.calendar.component(.hour, from: clock.now)
        let ageDays = max(0, clock.now.timeIntervalSince(observation.recordedAt) / 86_400)
        let recency = max(0, 4 - ageDays / 14)
        let weekdayBoost = observation.weekday == weekday ? 1.5 : 0
        let hourBoost = max(0, 2 - Double(hourDistance(hour, observation.hour)) * 0.5)
        let originBoost = proximityBoost(observation.origin, location: location)

        return 1
            + recency
            + weekdayBoost
            + hourBoost
            + originBoost
            + directionBoost(observation.direction, preferred: preferredDirection)
    }

    private func directionBoost(
        _ direction: CommuteDirection,
        preferred: CommuteDirection
    ) -> Double {
        if direction == preferred { return 8 }
        if direction == .anytime { return 3 }
        return 0
    }

    private func proximityBoost(
        _ observed: MobilityProfile.RouteLocation?,
        location: LastKnownLocation?
    ) -> Double {
        guard let observed, let location else { return 0 }
        let meters = Distance.meters(
            from: (observed.latitude, observed.longitude),
            to: (location.latitude, location.longitude)
        )
        if meters <= 800 { return 5 }
        if meters <= 3_000 { return 1.5 }
        return 0
    }

    private func hourDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let raw = abs(lhs - rhs)
        return min(raw, 24 - raw)
    }
}
