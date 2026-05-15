import Foundation
import TransitModels

/// Per-mode identity of a single arrival, used by the portfolio
/// evaluator to look up the corresponding bias correction. Carries the
/// agency-native identifiers `BiasCellKey` needs — line / stop /
/// direction — without forcing the evaluator to construct keys itself.
///
/// Metra and intercampus arrivals are intentionally omitted: neither is
/// graded by `ArrivalGrader` yet (passive grading needs vehicle next-
/// stop transitions, which Metra's GTFS-RT positions don't surface in a
/// usable form, and intercampus has no historical baseline at all).
public enum BiasArrivalRef: Sendable, Hashable {
    case train(line: LineColor, stopID: Int, directionCode: String)
    case bus(route: String, stopID: Int, directionName: String)
}

/// Read-only view on the per-cell bias statistics accumulated by
/// `ArrivalGrader`. Each call resolves the correct `BiasCellKey` from
/// `arrival` and `when`, runs the stored cell through
/// `ArrivalBiasCorrection.from(cell:)`, and returns the result.
///
/// `Sendable` so the portfolio evaluator can run off the main actor; the
/// underlying `ArrivalBiasStore` is `@MainActor`-isolated, so the app-
/// side conformance snapshots the cells before handing this off.
public protocol BiasCorrectionReader: Sendable {
    func correction(for arrival: BiasArrivalRef, at when: Date) -> ArrivalBiasCorrection?
}

/// Default concrete implementation. Wraps an injected
/// `(BiasCellKey) -> BiasCell?` closure — the same shape
/// `ArrivalBiasReader` uses for the dashboard's headline correction.
///
/// The closure must be `@Sendable` because this reader is handed to the
/// portfolio evaluator across isolation boundaries. The app target
/// captures a frozen `[BiasCellKey: BiasCell]` snapshot in the closure
/// rather than a live `ArrivalBiasStore` reference.
public struct BiasCellLookupReader: BiasCorrectionReader {
    public typealias CellLookup = @Sendable (BiasCellKey) -> BiasCell?

    public let cellLookup: CellLookup
    public let calendar: Calendar

    public init(cellLookup: @escaping CellLookup, calendar: Calendar = .current) {
        self.cellLookup = cellLookup
        self.calendar = calendar
    }

    public func correction(for arrival: BiasArrivalRef, at when: Date) -> ArrivalBiasCorrection? {
        let key: BiasCellKey
        switch arrival {
        case .train(let line, let stopID, let direction):
            key = BiasCellKey.make(
                line: line.rawValue,
                stopId: String(stopID),
                direction: direction,
                at: when,
                calendar: calendar
            )
        case .bus(let route, let stopID, let direction):
            key = BiasCellKey.make(
                line: route,
                stopId: String(stopID),
                direction: direction,
                at: when,
                calendar: calendar
            )
        }
        return ArrivalBiasCorrection.from(cell: cellLookup(key))
    }
}

/// Returns `nil` for every query. Used as the default in
/// `PortfolioSnapshot` and as a stand-in when the bias store hasn't been
/// hydrated yet (cold launch).
public struct EmptyBiasCorrectionReader: BiasCorrectionReader {
    public init() {}

    public func correction(for arrival: BiasArrivalRef, at when: Date) -> ArrivalBiasCorrection? {
        nil
    }
}
