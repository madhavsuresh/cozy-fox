import Foundation

/// Per-stop detour membership, sourced from CTA Bus Tracker v3 `getstops`.
/// A stop becomes "removed by detour" when one of the detour IDs in
/// `removedByDetourIds` is currently active (state == 1 in `BusDetour`).
///
/// Phase 2b: `BusReliabilityScorer` uses this to upgrade an active-detour
/// *warning* (from phase 2a) into a *removed-stop abstain*. The scorer
/// cross-references the active detour set with this list rather than
/// trusting any single field on its own — the same defensive shape the
/// cta-tight-arrivals prototype uses.
public struct BusStopDetourState: Codable, Sendable, Hashable, Identifiable {
    public let stopId: Int
    /// Detour IDs that *add* this stop temporarily. Surfaced for future
    /// "this stop is only served right now because of a detour" hints;
    /// not used by the scorer in phase 2b.
    public let addedByDetourIds: [String]
    /// Detour IDs that *remove* this stop. When any of them is active in
    /// the `BusDetour` cache, the scorer should abstain.
    public let removedByDetourIds: [String]

    public init(
        stopId: Int,
        addedByDetourIds: [String],
        removedByDetourIds: [String]
    ) {
        self.stopId = stopId
        self.addedByDetourIds = addedByDetourIds
        self.removedByDetourIds = removedByDetourIds
    }

    public var id: Int { stopId }

    /// Returns true when any of this stop's `removedByDetourIds` matches an
    /// active detour in `detours`.
    public func isRemovedBy(activeDetours detours: [BusDetour]) -> Bool {
        guard !removedByDetourIds.isEmpty else { return false }
        let activeIds = Set(detours.filter(\.isActive).map(\.id))
        return removedByDetourIds.contains(where: activeIds.contains)
    }
}
