import Foundation
import TransitCache
import TransitModels

/// Bundled per-tick inputs the portfolio evaluator needs. Pure value
/// container — every field is `Sendable` and the struct is immutable
/// once constructed. Built by `RefreshCoordinator` after the existing
/// `refreshAll` fan-out completes, then passed to
/// `PortfolioEvaluator.evaluate(...)` for each active portfolio.
///
/// Replaces what the earlier plan called a `NetworkState` protocol;
/// `TransitSnapshot` already plays exactly that role across all six
/// modes, so the snapshot composes around it rather than reinventing
/// it.
public struct PortfolioSnapshot: Sendable {
    /// The same aggregate the dashboard and widget read — train / bus /
    /// Metra / intercampus arrivals plus alerts and bike picks.
    public let snapshot: TransitSnapshot
    /// Reference moment for every freshness, leave-by, and ETA
    /// calculation. Defaults to `.now` but tests pin it for
    /// determinism.
    public let now: Date
    /// Where the user is. `nil` when location hasn't been resolved yet
    /// (cold launch, denied authorization). Evaluator's leg-walk
    /// calculations short-circuit when this is missing.
    public let userLocation: PlannerCoordinate?
    public let walkingDistance: any WalkingDistanceReader
    public let biasCorrection: any BiasCorrectionReader
    /// Stations the alerts feed currently flags as closed. Drives the
    /// `.closedStation([Int])` unavailability path on options whose
    /// legs touch one of these.
    public let closedStationIDs: Set<Int>

    public init(
        snapshot: TransitSnapshot,
        now: Date = .now,
        userLocation: PlannerCoordinate? = nil,
        walkingDistance: any WalkingDistanceReader = EmptyWalkingDistanceReader(),
        biasCorrection: any BiasCorrectionReader = EmptyBiasCorrectionReader(),
        closedStationIDs: Set<Int> = []
    ) {
        self.snapshot = snapshot
        self.now = now
        self.userLocation = userLocation
        self.walkingDistance = walkingDistance
        self.biasCorrection = biasCorrection
        self.closedStationIDs = closedStationIDs
    }
}
