import Foundation

public enum AlertSeverity: String, Codable, Sendable, Hashable {
    case low
    case medium
    case high
}

/// A CTA service alert. Map from the CustomerAlerts API.
public struct ServiceAlert: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let headline: String
    public let shortDescription: String
    public let severity: AlertSeverity
    public let impactedRoutes: [String]
    public let impactedLineColors: [LineColor]
    public let beginsAt: Date
    public let endsAt: Date?
    public let isMajor: Bool
    public let detailURL: URL?

    public init(
        id: String,
        headline: String,
        shortDescription: String,
        severity: AlertSeverity,
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
    func filtered(forLine line: LineColor?, busRoute: String?) -> [ServiceAlert] {
        guard line != nil || busRoute != nil else { return [] }
        return filter { alert in
            if let line, alert.impactedLineColors.contains(line) { return true }
            if let busRoute, alert.impactedRoutes.contains(busRoute) { return true }
            return false
        }
    }

    /// Multi-line / multi-route variant for the dashboard, where the user can
    /// have a pinned line + pinned bus + tracked routes all at once. With
    /// both sets empty we return `self` (no pinning context ⇒ "show
    /// everything") rather than the single-filter variant's empty.
    func filtered(forLines lines: Set<LineColor>, busRoutes: Set<String>) -> [ServiceAlert] {
        guard !lines.isEmpty || !busRoutes.isEmpty else { return self }
        return filter { alert in
            if !lines.isDisjoint(with: alert.impactedLineColors) { return true }
            if !Set(alert.impactedRoutes).isDisjoint(with: busRoutes) { return true }
            return false
        }
    }
}
