import Foundation

/// One of the user's tracked train arrivals: a station map id + direction.
public struct TrainPreference: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let mapId: Int
    public let stopId: Int?
    public let stationName: String
    public let line: LineColor
    public let directionLabel: String
    /// `.home` means "I take this when leaving home"; same for work.
    public let direction: CommuteDirection

    public init(
        id: UUID = UUID(),
        mapId: Int,
        stopId: Int?,
        stationName: String,
        line: LineColor,
        directionLabel: String,
        direction: CommuteDirection
    ) {
        self.id = id
        self.mapId = mapId
        self.stopId = stopId
        self.stationName = stationName
        self.line = line
        self.directionLabel = directionLabel
        self.direction = direction
    }
}

/// One of the user's tracked bus stops: a route + stop pair.
public struct BusPreference: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let route: String
    public let stopId: Int
    public let stopName: String
    public let directionLabel: String
    public let direction: CommuteDirection

    public init(
        id: UUID = UUID(),
        route: String,
        stopId: Int,
        stopName: String,
        directionLabel: String,
        direction: CommuteDirection
    ) {
        self.id = id
        self.route = route
        self.stopId = stopId
        self.stopName = stopName
        self.directionLabel = directionLabel
        self.direction = direction
    }
}

public enum CommuteDirection: String, Codable, Sendable, Hashable, CaseIterable {
    /// The leg you take when going **toward** Home.
    case toHome
    /// The leg you take when going **toward** Work.
    case toWork
    /// Not part of a daily commute — surface always.
    case anytime

    public var label: String {
        switch self {
        case .toHome: "Heading home"
        case .toWork: "Heading to work"
        case .anytime: "Anytime"
        }
    }
}

/// Top-level user preferences, persisted in App Group UserDefaults.
public struct UserRoutePreferences: Codable, Sendable, Hashable {
    public var trains: [TrainPreference]
    public var buses: [BusPreference]
    public var includeFreeFloatingBikes: Bool
    /// Auto-start a Live Activity on region exit (leaving home/work).
    /// Only meaningful when `alwaysShowLiveActivity == false`.
    public var autoStartLiveActivity: Bool
    /// Keep a Live Activity in the Dynamic Island / Lock Screen at all times
    /// while the app has authorization. Each refresh ensures it's running.
    public var alwaysShowLiveActivity: Bool
    /// User has explicitly pinned a specific L line. When set, the refresh
    /// path fetches arrivals at the nearest station serving this line and
    /// the Live Activity surfaces that line first.
    public var pinnedLine: LineColor?
    /// Specific station map_id the user chose on the pinned line. When nil
    /// the dashboard auto-picks the nearest station on `pinnedLine`. Cleared
    /// whenever `pinnedLine` changes.
    public var pinnedStationId: Int?
    /// Specific destination name (the CTA `destNm` field, e.g. "Howard", "95th")
    /// the user chose at the pinned station, so the Live Activity tracks one
    /// direction. Cleared whenever `pinnedLine` or `pinnedStationId` changes.
    public var pinnedTrainDestination: String?
    /// User has explicitly pinned a CTA bus route (e.g. "22", "X9", "147").
    /// When set, the refresh path fetches predictions at the nearest stop on
    /// that route. Optional MapKit-suggested route fills this in too.
    public var pinnedBusRoute: String?
    /// Direction label ("Northbound", "Eastbound", …) the user picked for
    /// the pinned bus route. Cleared whenever `pinnedBusRoute` changes.
    public var pinnedBusDirection: String?
    /// User-controlled override for the 30 s foreground refresh ticker. When
    /// off, the app falls back to pull-to-refresh + background tasks (which
    /// run every 15–45 min depending on commute window). iOS Low Power Mode
    /// overrides this to off regardless of the user setting.
    public var liveUpdatesEnabled: Bool

    public init(
        trains: [TrainPreference] = [],
        buses: [BusPreference] = [],
        includeFreeFloatingBikes: Bool = true,
        autoStartLiveActivity: Bool = true,
        alwaysShowLiveActivity: Bool = true,
        pinnedLine: LineColor? = nil,
        pinnedStationId: Int? = nil,
        pinnedTrainDestination: String? = nil,
        pinnedBusRoute: String? = nil,
        pinnedBusDirection: String? = nil,
        liveUpdatesEnabled: Bool = true
    ) {
        self.trains = trains
        self.buses = buses
        self.includeFreeFloatingBikes = includeFreeFloatingBikes
        self.autoStartLiveActivity = autoStartLiveActivity
        self.alwaysShowLiveActivity = alwaysShowLiveActivity
        self.pinnedLine = pinnedLine
        self.pinnedStationId = pinnedStationId
        self.pinnedTrainDestination = pinnedTrainDestination
        self.pinnedBusRoute = pinnedBusRoute
        self.pinnedBusDirection = pinnedBusDirection
        self.liveUpdatesEnabled = liveUpdatesEnabled
    }

    // Custom decoder so adding new fields stays backwards-compatible with
    // preferences blobs already on disk from older app versions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.trains = (try? c.decode([TrainPreference].self, forKey: .trains)) ?? []
        self.buses = (try? c.decode([BusPreference].self, forKey: .buses)) ?? []
        self.includeFreeFloatingBikes = (try? c.decode(Bool.self, forKey: .includeFreeFloatingBikes)) ?? true
        self.autoStartLiveActivity = (try? c.decode(Bool.self, forKey: .autoStartLiveActivity)) ?? true
        self.alwaysShowLiveActivity = (try? c.decode(Bool.self, forKey: .alwaysShowLiveActivity)) ?? true
        self.pinnedLine = try? c.decode(LineColor.self, forKey: .pinnedLine)
        self.pinnedStationId = try? c.decode(Int.self, forKey: .pinnedStationId)
        self.pinnedTrainDestination = try? c.decode(String.self, forKey: .pinnedTrainDestination)
        self.pinnedBusRoute = try? c.decode(String.self, forKey: .pinnedBusRoute)
        self.pinnedBusDirection = try? c.decode(String.self, forKey: .pinnedBusDirection)
        self.liveUpdatesEnabled = (try? c.decode(Bool.self, forKey: .liveUpdatesEnabled)) ?? true
    }

    public static let empty = UserRoutePreferences()
}
