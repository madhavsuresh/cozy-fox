import Foundation

/// A CTA Bus Tracker detour. Sourced from the `getdetours` endpoint.
///
/// A detour has a state (`isActive`), a description, the routes + directions
/// it affects, and optional start/end timestamps. Phase 2 uses these to add
/// a `DETOUR_ACTIVE` warning to `BusReliabilityScorer` when an active detour
/// covers the prediction's `(route, direction)`. Stop-level granularity
/// (which stops are *removed* by the detour) requires v3's
/// `getenhanceddetours` and lands in a later phase.
public struct BusDetour: Codable, Sendable, Hashable, Identifiable {
    public struct RouteDirection: Codable, Sendable, Hashable {
        public let route: String
        public let directionName: String

        public init(route: String, directionName: String) {
            self.route = route
            self.directionName = directionName
        }
    }

    public let id: String
    public let version: Int
    /// True when `st == 1` in the CTA response. CTA also publishes recently
    /// canceled detours; we keep them so a future reconciler can detect that
    /// a detour just ended, but `affects(...)` short-circuits when this is
    /// false.
    public let isActive: Bool
    public let summary: String
    public let affected: [RouteDirection]
    public let beginsAt: Date?
    public let endsAt: Date?

    public init(
        id: String,
        version: Int,
        isActive: Bool,
        summary: String,
        affected: [RouteDirection],
        beginsAt: Date?,
        endsAt: Date?
    ) {
        self.id = id
        self.version = version
        self.isActive = isActive
        self.summary = summary
        self.affected = affected
        self.beginsAt = beginsAt
        self.endsAt = endsAt
    }

    /// True when this detour is currently active *and* the route/direction
    /// match. Direction matches case-insensitively; passing `nil` for
    /// direction means "any direction on this route".
    public func affects(route: String, direction: String?, at moment: Date = .now) -> Bool {
        guard isActive else { return false }
        if let beginsAt, moment < beginsAt { return false }
        if let endsAt, moment > endsAt { return false }
        return affected.contains { rd in
            guard rd.route.caseInsensitiveCompare(route) == .orderedSame else { return false }
            guard let direction else { return true }
            return rd.directionName.caseInsensitiveCompare(direction) == .orderedSame
        }
    }
}

public extension Array where Element == BusDetour {
    /// Returns only the detours that are currently active for `(route,
    /// direction)`. Convenience for the scorer + UI surfaces.
    func active(forRoute route: String, direction: String?, at moment: Date = .now) -> [BusDetour] {
        filter { $0.affects(route: route, direction: direction, at: moment) }
    }
}
