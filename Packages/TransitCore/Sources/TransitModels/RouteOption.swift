import Foundation

/// One specific way to make a trip — a sequence of legs (walking + transit)
/// from origin to destination. The user can author multiple `RouteOption`s
/// for the same `RoutePortfolio`; the evaluator picks the best one each
/// refresh tick based on live arrivals, transfer feasibility, and bias.
///
/// The shape here is structural — origin/destination/legs as static
/// references. The transient evaluation (ETA, miss cost, recommended)
/// lives in `RouteEvaluation` (TransitDomain).
public struct RouteOption: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var label: String
    public var role: RouteOptionRole
    public var legs: [RouteOptionLeg]

    public init(
        id: UUID = UUID(),
        label: String,
        role: RouteOptionRole = .primary,
        legs: [RouteOptionLeg]
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.legs = legs
    }
}

/// What this option contributes to the portfolio: the user's default,
/// a faster-but-riskier choice, a higher-reliability fallback, or a
/// last-resort backup (bad weather, late night, etc.).
public enum RouteOptionRole: String, Codable, Sendable, Hashable, CaseIterable {
    /// The user's default — what to surface when conditions are normal.
    case primary
    /// Tight transfer, lower walking time; faster if hit.
    case fastRisky
    /// Higher reliability, longer walking time.
    case slowSafe
    /// Last-resort fallback: weather, service disruption, late night.
    case fallback
}

public struct RouteOptionLeg: Codable, Sendable, Hashable {
    public var mode: TripLegMode
    /// Populated only when `mode == .transit`.
    public var transit: TransitLegInfo?
    /// The board stop for a transit leg, or the start of a walking leg.
    /// Nil for the very first leg of a portfolio when the origin is a
    /// `PortfolioAnchor` rather than a catalog stop.
    public var fromStopID: TransitStopRef?
    /// The alight stop for a transit leg, or the end of a walking leg.
    /// Nil for the final leg ending at a `PortfolioAnchor`.
    public var toStopID: TransitStopRef?
    public var approximateDistanceMeters: Double

    public init(
        mode: TripLegMode,
        transit: TransitLegInfo? = nil,
        fromStopID: TransitStopRef? = nil,
        toStopID: TransitStopRef? = nil,
        approximateDistanceMeters: Double
    ) {
        self.mode = mode
        self.transit = transit
        self.fromStopID = fromStopID
        self.toStopID = toStopID
        self.approximateDistanceMeters = approximateDistanceMeters
    }
}

/// One identifier shape across the four mode-specific catalogs. Lets
/// `RouteOptionLeg` point at "the stop" without forcing a unifying Stop
/// protocol over `LStation`, `BusStop`, `MetraStation`, `IntercampusStop`.
public enum TransitStopRef: Codable, Sendable, Hashable {
    /// `LStation.id` — station-level CTA L identifier (the `mapid` the
    /// Train Tracker accepts).
    case lStation(Int)
    /// `LPlatform.id` — platform-level CTA L identifier (the `stpid` the
    /// Train Tracker accepts for direction-specific queries).
    case lPlatform(Int)
    /// `BusStop.id` — CTA bus stop identifier.
    case bus(Int)
    /// `MetraStation.id` — Metra station identifier (e.g. "PALATINE").
    case metra(String)
    /// `AmtrakStation.id` — Amtrak station code (e.g. "CHI").
    case amtrak(String)
    /// `IntercampusStop.id` — Northwestern TripShot stop identifier.
    case intercampus(String)
}
