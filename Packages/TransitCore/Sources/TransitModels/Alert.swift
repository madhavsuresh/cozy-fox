import Foundation

public enum AlertSeverity: String, Codable, Sendable, Hashable {
    case low
    case medium
    case high
}

public enum ServiceAlertProvider: String, Codable, Sendable, Hashable {
    case cta
    case metra
    case amtrak
}

/// A provider service alert or notice normalized into the shared alert surface.
public struct ServiceAlert: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let headline: String
    public let shortDescription: String
    public let severity: AlertSeverity
    public let provider: ServiceAlertProvider
    public let sourceLabel: String
    public let impactedRoutes: [String]
    public let impactedLineColors: [LineColor]
    public let beginsAt: Date
    public let endsAt: Date?
    public let isMajor: Bool
    public let detailURL: URL?

    /// Public CTA service-alerts page. The Customer Alerts API hands out a
    /// per-alert `alert_detail.aspx` URL, but CTA stopped rendering that page
    /// — every per-alert link resolves to a "not found" view. The alerts hub
    /// is the page CTA actually maintains and surfaces from their site nav,
    /// so every "Details" link in the app deep-links there instead.
    public static let detailsURL = URL(string: "https://www.transitchicago.com/alerts/")!
    public static let metraDetailsURL = URL(string: "https://metra.com/service-alerts")!
    public static let amtrakDetailsURL = URL(string: "https://www.amtrak.com/service-alerts-and-notices")!

    public init(
        id: String,
        headline: String,
        shortDescription: String,
        severity: AlertSeverity,
        provider: ServiceAlertProvider = .cta,
        sourceLabel: String = "Service alert",
        impactedRoutes: [String],
        impactedLineColors: [LineColor],
        beginsAt: Date,
        endsAt: Date?,
        isMajor: Bool,
        detailURL: URL? = nil
    ) {
        self.id = id
        self.headline = headline
        self.shortDescription = shortDescription
        self.severity = severity
        self.provider = provider
        self.sourceLabel = sourceLabel
        self.impactedRoutes = impactedRoutes
        self.impactedLineColors = impactedLineColors
        self.beginsAt = beginsAt
        self.endsAt = endsAt
        self.isMajor = isMajor
        self.detailURL = detailURL
    }

    public func isActive(at moment: Date = .now) -> Bool {
        guard moment >= beginsAt else { return false }
        if let endsAt { return moment <= endsAt }
        return true
    }
}

public extension Array where Element == ServiceAlert {
    /// Keeps only alerts whose impact set intersects with what the surface is
    /// actually showing. With both filters nil there's no relevant context, so
    /// nothing is surfaced.
    func filtered(forLine line: LineColor?, busRoute: String?, metraRoute: String? = nil, amtrakRoute: String? = nil) -> [ServiceAlert] {
        guard line != nil || busRoute != nil || metraRoute != nil || amtrakRoute != nil else { return [] }
        return filter { alert in
            if let line, alert.impactedLineColors.contains(line) { return true }
            if let busRoute, alert.impactedRoutes.contains(busRoute) { return true }
            if let metraRoute, alert.impactedRoutes.contains(metraRoute) { return true }
            if let amtrakRoute, alert.provider == .amtrak {
                return alert.impactedRoutes.isEmpty || alert.impactedRoutes.contains(amtrakRoute)
            }
            return false
        }
    }

    /// Multi-line / multi-route variant for the dashboard, where the user can
    /// have a pinned line + pinned bus + tracked routes all at once. With
    /// both sets empty we return `self` (no pinning context ⇒ "show
    /// everything") rather than the single-filter variant's empty.
    func filtered(forLines lines: Set<LineColor>, busRoutes: Set<String>, metraRoutes: Set<String> = [], amtrakRoutes: Set<String> = []) -> [ServiceAlert] {
        guard !lines.isEmpty || !busRoutes.isEmpty || !metraRoutes.isEmpty || !amtrakRoutes.isEmpty else { return self }
        return filter { alert in
            if !lines.isDisjoint(with: alert.impactedLineColors) { return true }
            if !Set(alert.impactedRoutes).isDisjoint(with: busRoutes) { return true }
            if !Set(alert.impactedRoutes).isDisjoint(with: metraRoutes) { return true }
            if !amtrakRoutes.isEmpty,
               alert.provider == .amtrak,
               (alert.impactedRoutes.isEmpty || !Set(alert.impactedRoutes).isDisjoint(with: amtrakRoutes)) {
                return true
            }
            return false
        }
    }
}
