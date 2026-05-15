import Foundation
import TransitModels

/// Read-only view on the user's MapKit walking-time cache, scaled by the
/// learned per-user walk-speed correction when confident. Returns seconds
/// (more directly useful than meters for miss-cost arithmetic) and `nil`
/// when no fresh estimate exists for the requested origin × destination.
///
/// `Sendable` so the portfolio evaluator can run off the main actor; the
/// underlying `WalkingDistanceStore` is `@MainActor`-isolated, so the
/// app-side conformance snapshots `distances` + `walkSpeedEstimate`
/// before handing this off.
public protocol WalkingDistanceReader: Sendable {
    func walkSeconds(
        from origin: (lat: Double, lon: Double),
        to destination: TransitStopRef
    ) -> TimeInterval?
}

/// Returns `nil` for every query. Used as the default in
/// `PortfolioSnapshot` and as a stand-in when the walking cache hasn't
/// been hydrated yet.
public struct EmptyWalkingDistanceReader: WalkingDistanceReader {
    public init() {}

    public func walkSeconds(
        from origin: (lat: Double, lon: Double),
        to destination: TransitStopRef
    ) -> TimeInterval? {
        nil
    }
}
