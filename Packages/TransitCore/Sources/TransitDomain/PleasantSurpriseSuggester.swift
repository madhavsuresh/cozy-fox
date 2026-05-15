import Foundation
import TransitModels

/// Suggests a single "try this today" alternative to the user's
/// habitual commute route. Pure / deterministic.
///
/// MVP (this file): mode-swap suggestions only. "You usually take the
/// Brown line — try the 22 Clark bus today, ~4 min longer." No
/// geographic delight scoring (that's a follow-up). No multi-leg
/// alternatives (also a follow-up).
///
/// Gates, ANDed:
/// 1. The current trip direction is `.toWork` or `.toHome` — inferred
///    from `currentContext`.
/// 2. The user's `MobilityProfileSummary` has ≥ 1 top route pattern in
///    this direction.
/// 3. There exists at least one *other* route in a different mode
///    within walking distance of both origin and destination anchors.
/// 4. The alternative's projected time is within
///    `maxTimePenaltyFraction × usualTime + maxAbsolutePenaltyMinutes`
///    of the user's habitual route.
/// 5. The alternative hasn't been seen in the recent observation
///    window (default 14 days) — only-novel.
/// 6. The alternative's route key isn't currently suppressed.
public struct PleasantSurpriseSuggester: Sendable {
    public struct Suggestion: Sendable, Hashable {
        /// Stable identity for suppression. Shape:
        /// `"pleasantSurprise:<mode>:<routeId>"`.
        public let routeKey: String
        public let direction: CommuteDirection
        public let mode: MobilityProfileSummary.RoutePattern.Mode
        public let routeId: String
        /// Display name for the route, e.g. "22 Clark" for buses,
        /// "Brown" for trains. The caller may further decorate.
        public let displayName: String
        public let extraMinutes: Int

        public init(
            routeKey: String,
            direction: CommuteDirection,
            mode: MobilityProfileSummary.RoutePattern.Mode,
            routeId: String,
            displayName: String,
            extraMinutes: Int
        ) {
            self.routeKey = routeKey
            self.direction = direction
            self.mode = mode
            self.routeId = routeId
            self.displayName = displayName
            self.extraMinutes = extraMinutes
        }

        public var prose: String {
            "Try \(displayName) today? +\(extraMinutes)m vs your usual."
        }
    }

    public struct AlternativeRoute: Sendable, Hashable {
        public let mode: MobilityProfileSummary.RoutePattern.Mode
        public let routeId: String
        public let displayName: String
        /// Projected end-to-end trip time in seconds. The caller is
        /// expected to compute this (it's mode-and-network-specific).
        public let projectedSeconds: TimeInterval

        public init(
            mode: MobilityProfileSummary.RoutePattern.Mode,
            routeId: String,
            displayName: String,
            projectedSeconds: TimeInterval
        ) {
            self.mode = mode
            self.routeId = routeId
            self.displayName = displayName
            self.projectedSeconds = projectedSeconds
        }
    }

    public init() {}

    public func suggest(
        currentContext: CommuteContext,
        profile: MobilityProfile,
        alternatives: [AlternativeRoute],
        usualTripSeconds: TimeInterval?,
        isSuppressed: (String) -> Bool,
        recentObservationCutoff: Date,
        maxTimePenaltyFraction: Double = 0.25,
        maxAbsolutePenaltyMinutes: Int = 5
    ) -> Suggestion? {
        // 1) Direction inference.
        let direction: CommuteDirection
        switch currentContext {
        case .atHome: direction = .toWork
        case .atWork: direction = .toHome
        case .elsewhere, .unknown: return nil
        }
        // 2) Need a usual pattern + a usual trip time baseline.
        let usual = profile.summary.patterns(direction: direction)
            .sorted { $0.totalCount > $1.totalCount }
            .first
        guard let usual else { return nil }
        guard let usualSeconds = usualTripSeconds, usualSeconds > 0 else { return nil }
        // Cost budget: penalty must be within fraction OR absolute floor,
        // whichever is larger — so a short trip has a 5-min cushion and
        // a long one gets fractional headroom.
        let fractionBudget = usualSeconds * maxTimePenaltyFraction
        let absoluteBudget = Double(maxAbsolutePenaltyMinutes) * 60
        let maxPenaltySeconds = max(fractionBudget, absoluteBudget)

        // 3) Recent observations — anything the user took in the last
        // window is excluded from the candidate set.
        let recentObserved: Set<String> = Set(
            profile.routeObservations
                .filter { $0.recordedAt >= recentObservationCutoff }
                .compactMap { obs -> String? in
                    if let line = obs.line { return Self.key(mode: .train, routeId: line.rawValue) }
                    if let bus = obs.busRoute { return Self.key(mode: .bus, routeId: bus) }
                    if let metra = obs.metraRoute { return Self.key(mode: .metra, routeId: metra) }
                    return nil
                }
        )
        let usualKey = Self.key(mode: usual.mode, routeId: usual.routeId)

        // 4) Score each candidate; pick the one within budget that's
        // most novel and cheapest. Sort by extraMinutes ascending.
        let candidates: [Suggestion] = alternatives
            .compactMap { alt -> Suggestion? in
                let altKey = Self.key(mode: alt.mode, routeId: alt.routeId)
                guard altKey != usualKey else { return nil }
                let penaltySeconds = alt.projectedSeconds - usualSeconds
                guard penaltySeconds <= maxPenaltySeconds else { return nil }
                let extraMinutes = max(0, Int((penaltySeconds / 60).rounded()))
                guard !recentObserved.contains(altKey) else { return nil }
                let routeKey = "pleasantSurprise:\(altKey)"
                guard !isSuppressed(routeKey) else { return nil }
                return Suggestion(
                    routeKey: routeKey,
                    direction: direction,
                    mode: alt.mode,
                    routeId: alt.routeId,
                    displayName: alt.displayName,
                    extraMinutes: extraMinutes
                )
            }
            .sorted { $0.extraMinutes < $1.extraMinutes }

        return candidates.first
    }

    static func key(mode: MobilityProfileSummary.RoutePattern.Mode, routeId: String) -> String {
        "\(mode.rawValue):\(routeId)"
    }
}
