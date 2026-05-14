import Foundation
import TransitModels

/// Bridge between a list of `Arrival`s and the `ArrivalBiasCorrection`
/// that should accompany the *headline* (first) arrival. The reader
/// derives the `BiasCellKey` from the first arrival's identity and
/// time-of-day, calls the injected `CellLookup`, and runs the cell
/// through `ArrivalBiasCorrection.from(cell:)`.
///
/// Why the `CellLookup` closure rather than a direct reference to
/// `ArrivalBiasStore`?
///
/// - `ArrivalBiasStore` is `@MainActor` and lives in the CozyFox app
///   target. `TransitDomain` is a generic, non-app-isolated library;
///   pulling the store into the dependency graph would force every
///   consumer onto the main actor.
/// - Tests can inject a deterministic `(BiasCellKey) -> BiasCell?`
///   without spinning up a real store. See `ArrivalBiasReaderTests`.
public struct ArrivalBiasReader: Sendable {
    /// Closure that resolves a stored cell for a given key. Returns
    /// `nil` when the store has no signal for that bucket.
    public typealias CellLookup = @Sendable (BiasCellKey) -> BiasCell?

    public init() {}

    /// Look up the correction for the *first* arrival in `arrivals`.
    /// Returns `nil` when:
    /// - `arrivals` is empty (no headline to correct)
    /// - the stored cell is missing or fails the confidence gates in
    ///   `ArrivalBiasCorrection.from(cell:)`
    ///
    /// The bucket is keyed off the trip's own `arrivalAt` (NOT
    /// `Date.now`), so an arrival currently 30 minutes out is graded
    /// against the cell for the hour it actually lands in. That keeps
    /// late-evening predictions from being judged by the morning's
    /// reliability.
    public func headlineCorrection(
        arrivals: [Arrival],
        cellLookup: CellLookup,
        calendar: Calendar = .current
    ) -> ArrivalBiasCorrection? {
        guard let first = arrivals.first else { return nil }
        let key = BiasCellKey.make(
            line: first.line.rawValue,
            stopId: String(first.stopId),
            direction: first.directionCode,
            at: first.arrivalAt,
            calendar: calendar
        )
        return ArrivalBiasCorrection.from(cell: cellLookup(key))
    }
}
