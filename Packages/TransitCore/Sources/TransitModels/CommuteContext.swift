import Foundation

/// Inferred from region monitoring + time of day. Drives which direction the
/// widget surfaces by default.
public enum CommuteContext: String, Codable, Sendable, Hashable, CaseIterable {
    case atHome
    case atWork
    case elsewhere
    case unknown

    public var preferredDirection: CommuteDirection {
        switch self {
        case .atHome: .toWork
        case .atWork: .toHome
        case .elsewhere: .anytime
        case .unknown: .anytime
        }
    }
}

/// A pair of geographic anchors (Home, Work) the user sets during onboarding.
public struct CommuteAnchors: Codable, Sendable, Hashable {
    public struct Anchor: Codable, Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double
        public let label: String

        public init(latitude: Double, longitude: Double, label: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.label = label
        }
    }

    public var home: Anchor?
    public var work: Anchor?

    public init(home: Anchor? = nil, work: Anchor? = nil) {
        self.home = home
        self.work = work
    }

    public static let empty = CommuteAnchors()
}

/// Last known location stored in the cache for the widget to read.
public struct LastKnownLocation: Codable, Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double
    public let recordedAt: Date
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case foreground
        case regionEntry
        case regionExit
        case significantChange
        case onboarding
    }

    public init(
        latitude: Double,
        longitude: Double,
        recordedAt: Date,
        source: Source
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.recordedAt = recordedAt
        self.source = source
    }
}
