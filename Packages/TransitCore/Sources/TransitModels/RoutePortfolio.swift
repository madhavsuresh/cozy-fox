import Foundation

/// A bundle of `RouteOption`s representing all the known ways the user
/// takes a recurring trip — e.g. "home from work" might contain a primary
/// L-line option, a faster-but-riskier bus option, and a slow-safe Metra
/// fallback. The portfolio is the persistent surface; the per-refresh
/// recommendation (`RouteEvaluation`) is transient.
///
/// Portfolios coexist with the single-pin model (`pinnedLine`,
/// `pinnedBusRoute`, `pinnedMetraRoute`, `plannedTripPin`) on
/// `UserRoutePreferences`. Users without portfolios see no change.
public struct RoutePortfolio: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var direction: CommuteDirection
    public var origin: PortfolioAnchor
    public var destination: PortfolioAnchor
    public var options: [RouteOption]
    public var createdAt: Date
    public var lastEvaluatedAt: Date?
    /// The `RouteOption.id` last surfaced as the recommendation. Drives
    /// hysteresis — `RefreshCoordinator` only switches when the new argmax
    /// beats this by enough delta for long enough.
    public var lastRecommendedOptionID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        direction: CommuteDirection,
        origin: PortfolioAnchor,
        destination: PortfolioAnchor,
        options: [RouteOption] = [],
        createdAt: Date = .now,
        lastEvaluatedAt: Date? = nil,
        lastRecommendedOptionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.direction = direction
        self.origin = origin
        self.destination = destination
        self.options = options
        self.createdAt = createdAt
        self.lastEvaluatedAt = lastEvaluatedAt
        self.lastRecommendedOptionID = lastRecommendedOptionID
    }
}

/// Where a portfolio starts or ends. `home` / `work` rebind to the user's
/// current `CommuteAnchors.home` / `.work` at evaluation time, so anchors
/// stay editable without churning the portfolio. `coordinate` carries an
/// explicit lat/lon for portfolios that don't terminate at a known anchor.
public enum PortfolioAnchor: Codable, Sendable, Hashable {
    case home
    case work
    case coordinate(latitude: Double, longitude: Double, label: String)
}
