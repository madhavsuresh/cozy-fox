import Foundation
import TransitModels

/// Per-tick evaluation of a single `RouteOption` under current conditions.
/// Transient — produced by `PortfolioEvaluator.evaluate(...)` each refresh
/// cycle. Never persisted; the portfolio (in `UserRoutePreferences`) is
/// the source of truth, this is the derived view.
public struct RouteEvaluation: Sendable, Hashable, Identifiable {
    public var id: UUID { optionID }
    public let optionID: UUID
    public let available: Bool
    /// Headline ETA — when the user is expected to arrive at the
    /// destination if they take this option starting now.
    public let etaMedian: Date
    /// Spread on `etaMedian` derived from `ArrivalBiasStore`'s historical
    /// learning, aggregated across transit legs. Zero when no confident
    /// bias data exists for any leg.
    public let etaStdDev: TimeInterval
    /// `[0, 1]` — probability the option fails (no catchable vehicle,
    /// missed transfer, etc.) within the evaluation horizon.
    public let pFailure: Double
    public let transferCount: Int
    /// When the user must leave their current location to make this
    /// option's first vehicle. Equal to `imminentVehicle.arrivalAt -
    /// walkTime` for transit options; equal to `etaMedian -
    /// totalWalkTime` for walking-only options.
    public let nextActionDeadline: Date
    /// `[0, 1]` minimum of per-leg confidences. Zero when any leg lacks a
    /// catchable vehicle in horizon.
    public let confidence: Double
    /// The specific vehicle the evaluator picked as "the one to catch" for
    /// this option's first transit leg. `nil` for walking-only options or
    /// when no vehicle is available within horizon.
    public let imminentVehicle: ImminentVehicle?
    /// Set when `available == false`. Drives the unavailability
    /// annotation on the dashboard card.
    public let unavailableReason: UnavailableReason?

    public init(
        optionID: UUID,
        available: Bool,
        etaMedian: Date,
        etaStdDev: TimeInterval,
        pFailure: Double,
        transferCount: Int,
        nextActionDeadline: Date,
        confidence: Double,
        imminentVehicle: ImminentVehicle? = nil,
        unavailableReason: UnavailableReason? = nil
    ) {
        self.optionID = optionID
        self.available = available
        self.etaMedian = etaMedian
        self.etaStdDev = etaStdDev
        self.pFailure = pFailure
        self.transferCount = transferCount
        self.nextActionDeadline = nextActionDeadline
        self.confidence = confidence
        self.imminentVehicle = imminentVehicle
        self.unavailableReason = unavailableReason
    }
}

/// The specific vehicle the evaluator picked as "the one to catch" for an
/// option's first transit leg. Each case carries the agency-native
/// identifiers the corresponding API client already returns, so callers
/// can filter `TransitSnapshot` without a unifying Stop protocol.
public enum ImminentVehicle: Sendable, Hashable {
    case train(runNumber: String, stationID: Int, line: LineColor)
    case bus(vehicleID: String, stopID: Int, route: String)
    case metra(tripID: String, stationID: String, route: String)
    case intercampus(tripID: String, stopID: String, direction: IntercampusDirection)
}

public enum UnavailableReason: Sendable, Hashable {
    /// No vehicle in the evaluation horizon (default 45 min; 90 min when
    /// `LastTrainSafety` flags last-train).
    case noArrivalsInHorizon
    /// The latest viable vehicle for this option has already passed.
    case lastVehicleAlreadyPassed
    /// The relevant feed hasn't refreshed within its staleness TTL.
    case staleFeed
    /// The user is too far from this option's first stop for a feasible
    /// walk before the next arrival.
    case userTooFar
    /// One or more stations along this option are closed (per
    /// `ClosedStationsAnalyzer.closedStationIds`). Carries the closed
    /// station IDs so the UI can name the blocking station.
    case closedStation([Int])
}
