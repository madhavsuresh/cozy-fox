import Foundation

/// What kind of motion a leg represents.
public enum TripLegMode: String, Codable, Sendable, Hashable {
    case walking
    case transit
    case other
}

/// Cross-referenced CTA identifier for a transit leg.
public enum TransitResolution: Codable, Sendable, Hashable {
    /// Matched an L line — e.g. "Blue Line" → `.blue`.
    case line(LineColor)
    /// Matched a CTA bus route in `BusStopCatalog.allRoutes`.
    case bus(String)
    /// Matched a Metra commuter-rail line, e.g. "BNSF" or "UP-N".
    case metra(String)
    /// Matched an Amtrak intercity rail or Thruway route.
    case amtrak(String)
    /// Apple returned a transit string we could not map (commuter rail,
    /// out-of-area bus, etc.). Surface the raw text so the UI can still show
    /// something useful.
    case unknown(String)
}

public struct TransitLegInfo: Codable, Sendable, Hashable {
    /// Best human-readable name we extracted ("Blue Line", "Route 65", "Metra UP-N").
    public let rawName: String
    public let resolution: TransitResolution

    public init(rawName: String, resolution: TransitResolution) {
        self.rawName = rawName
        self.resolution = resolution
    }
}
