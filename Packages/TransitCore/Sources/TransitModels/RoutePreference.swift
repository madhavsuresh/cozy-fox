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

/// One of the user's tracked Metra stations: a line + station pair.
public struct MetraPreference: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let routeId: String
    public let stationId: String
    public let stationName: String
    public let directionId: Int?
    public let directionLabel: String
    public let direction: CommuteDirection

    public init(
        id: UUID = UUID(),
        routeId: String,
        stationId: String,
        stationName: String,
        directionId: Int?,
        directionLabel: String,
        direction: CommuteDirection
    ) {
        self.id = id
        self.routeId = routeId
        self.stationId = stationId
        self.stationName = stationName
        self.directionId = directionId
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

public enum RoutePinSource: String, Codable, Sendable, Hashable {
    case manual
    case automatic

    public var label: String {
        switch self {
        case .manual: "Manual pin"
        case .automatic: "Autopin"
        }
    }
}

public enum TransitVisibilityMode: String, Codable, Sendable, Hashable, CaseIterable {
    case trains
    case buses
    case metra
    case bikes
    case intercampus

    public var label: String {
        switch self {
        case .trains: "Trains"
        case .buses: "Buses"
        case .metra: "Metra"
        case .bikes: "Divvy"
        case .intercampus: "Intercampus"
        }
    }
}

public struct PlannedTripPin: Codable, Sendable, Hashable, Identifiable {
    public enum DestinationKind: String, Codable, Sendable, Hashable {
        case home
        case work
        case custom

        var defaultTitle: String {
            switch self {
            case .home: "Home"
            case .work: "Work"
            case .custom: "Destination"
            }
        }
    }

    public struct Destination: Codable, Sendable, Hashable {
        public let kind: DestinationKind
        public let title: String
        public let subtitle: String?
        public let latitude: Double?
        public let longitude: Double?

        public init(
            kind: DestinationKind,
            title: String,
            subtitle: String? = nil,
            latitude: Double?,
            longitude: Double?
        ) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.latitude = latitude
            self.longitude = longitude
        }

        public var label: String {
            title
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case title
            case subtitle
            case latitude
            case longitude
        }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               let kind = try? container.decode(DestinationKind.self, forKey: .kind) {
                self.kind = kind
                self.title = (try? container.decode(String.self, forKey: .title)) ?? kind.defaultTitle
                self.subtitle = try? container.decode(String.self, forKey: .subtitle)
                self.latitude = try? container.decode(Double.self, forKey: .latitude)
                self.longitude = try? container.decode(Double.self, forKey: .longitude)
                return
            }

            let rawValue = try decoder.singleValueContainer().decode(String.self)
            let kind = DestinationKind(rawValue: rawValue) ?? .custom
            self.kind = kind
            self.title = kind.defaultTitle
            self.subtitle = nil
            self.latitude = nil
            self.longitude = nil
        }
    }

    public struct TrainLeg: Codable, Sendable, Hashable {
        public let line: LineColor
        public let stationId: Int?
        public let stationName: String
        public let destinationName: String?

        public init(
            line: LineColor,
            stationId: Int?,
            stationName: String,
            destinationName: String? = nil
        ) {
            self.line = line
            self.stationId = stationId
            self.stationName = stationName
            self.destinationName = destinationName
        }
    }

    public struct BusLeg: Codable, Sendable, Hashable {
        public let route: String
        public let stopId: Int?
        public let stopName: String
        public let directionLabel: String?

        public init(
            route: String,
            stopId: Int?,
            stopName: String,
            directionLabel: String? = nil
        ) {
            self.route = route
            self.stopId = stopId
            self.stopName = stopName
            self.directionLabel = directionLabel
        }
    }

    public struct MetraLeg: Codable, Sendable, Hashable {
        public let routeId: String
        public let stationId: String?
        public let stationName: String
        public let directionId: Int?
        public let destinationName: String?

        public init(
            routeId: String,
            stationId: String?,
            stationName: String,
            directionId: Int? = nil,
            destinationName: String? = nil
        ) {
            self.routeId = routeId
            self.stationId = stationId
            self.stationName = stationName
            self.directionId = directionId
            self.destinationName = destinationName
        }
    }

    public let id: UUID
    public let destination: Destination
    public let title: String
    public let summary: String
    public let createdAt: Date
    public let expectedArrivalAt: Date?
    public let expectedTravelTime: TimeInterval
    public let allowMultimodal: Bool
    public let includeDivvyInfo: Bool
    public let trainLegs: [TrainLeg]
    public let busLegs: [BusLeg]
    public let metraLegs: [MetraLeg]

    public var train: TrainLeg? { trainLegs.first }
    public var bus: BusLeg? { busLegs.first }
    public var metra: MetraLeg? { metraLegs.first }

    public init(
        id: UUID = UUID(),
        destination: Destination,
        title: String,
        summary: String,
        createdAt: Date = .now,
        expectedArrivalAt: Date?,
        expectedTravelTime: TimeInterval,
        allowMultimodal: Bool,
        includeDivvyInfo: Bool = true,
        train: TrainLeg?,
        bus: BusLeg?,
        metra: MetraLeg? = nil,
        trainLegs: [TrainLeg]? = nil,
        busLegs: [BusLeg]? = nil,
        metraLegs: [MetraLeg]? = nil
    ) {
        self.id = id
        self.destination = destination
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.expectedArrivalAt = expectedArrivalAt
        self.expectedTravelTime = expectedTravelTime
        self.allowMultimodal = allowMultimodal
        self.includeDivvyInfo = includeDivvyInfo
        self.trainLegs = trainLegs ?? train.map { [$0] } ?? []
        self.busLegs = busLegs ?? bus.map { [$0] } ?? []
        self.metraLegs = metraLegs ?? metra.map { [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case destination
        case title
        case summary
        case createdAt
        case expectedArrivalAt
        case expectedTravelTime
        case allowMultimodal
        case includeDivvyInfo
        case train
        case bus
        case metra
        case trainLegs
        case busLegs
        case metraLegs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.destination = try c.decode(Destination.self, forKey: .destination)
        self.title = try c.decode(String.self, forKey: .title)
        self.summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .now
        self.expectedArrivalAt = try? c.decode(Date.self, forKey: .expectedArrivalAt)
        self.expectedTravelTime = (try? c.decode(TimeInterval.self, forKey: .expectedTravelTime)) ?? 0
        self.allowMultimodal = (try? c.decode(Bool.self, forKey: .allowMultimodal)) ?? true
        self.includeDivvyInfo = (try? c.decode(Bool.self, forKey: .includeDivvyInfo)) ?? true

        let legacyTrain = try? c.decode(TrainLeg.self, forKey: .train)
        let legacyBus = try? c.decode(BusLeg.self, forKey: .bus)
        let legacyMetra = try? c.decode(MetraLeg.self, forKey: .metra)
        self.trainLegs = (try? c.decode([TrainLeg].self, forKey: .trainLegs)) ?? legacyTrain.map { [$0] } ?? []
        self.busLegs = (try? c.decode([BusLeg].self, forKey: .busLegs)) ?? legacyBus.map { [$0] } ?? []
        self.metraLegs = (try? c.decode([MetraLeg].self, forKey: .metraLegs)) ?? legacyMetra.map { [$0] } ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(destination, forKey: .destination)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(expectedArrivalAt, forKey: .expectedArrivalAt)
        try c.encode(expectedTravelTime, forKey: .expectedTravelTime)
        try c.encode(allowMultimodal, forKey: .allowMultimodal)
        try c.encode(includeDivvyInfo, forKey: .includeDivvyInfo)
        try c.encodeIfPresent(train, forKey: .train)
        try c.encodeIfPresent(bus, forKey: .bus)
        try c.encodeIfPresent(metra, forKey: .metra)
        try c.encode(trainLegs, forKey: .trainLegs)
        try c.encode(busLegs, forKey: .busLegs)
        try c.encode(metraLegs, forKey: .metraLegs)
    }

    public func withIncludeDivvyInfo(_ includeDivvyInfo: Bool) -> PlannedTripPin {
        PlannedTripPin(
            id: id,
            destination: destination,
            title: title,
            summary: summary,
            createdAt: createdAt,
            expectedArrivalAt: expectedArrivalAt,
            expectedTravelTime: expectedTravelTime,
            allowMultimodal: allowMultimodal,
            includeDivvyInfo: includeDivvyInfo,
            train: train,
            bus: bus,
            metra: metra,
            trainLegs: trainLegs,
            busLegs: busLegs,
            metraLegs: metraLegs
        )
    }

    public func isExpired(now: Date = .now) -> Bool {
        guard let expectedArrivalAt else {
            return now.timeIntervalSince(createdAt) > 2 * 60 * 60
        }
        return now > expectedArrivalAt.addingTimeInterval(10 * 60)
    }
}

/// Top-level user preferences, persisted in App Group UserDefaults.
public struct UserRoutePreferences: Codable, Sendable, Hashable {
    public var trains: [TrainPreference]
    public var buses: [BusPreference]
    public var metra: [MetraPreference]
    public var includeFreeFloatingBikes: Bool
    /// Modes hidden from discovery, pickers, widgets, planning, and default
    /// refresh targets. Existing pinned items still render until cleared.
    public var hiddenModes: Set<TransitVisibilityMode>
    /// Individual L lines hidden from discovery and route pickers.
    public var hiddenTrainLines: Set<LineColor>
    /// Individual CTA bus routes hidden from discovery and route pickers.
    public var hiddenBusRoutes: Set<String>
    /// Individual Metra routes hidden from discovery and route pickers.
    public var hiddenMetraRoutes: Set<String>
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
    /// Destination names (the CTA `destNm` field, e.g. "Howard", "95th")
    /// the user chose at the pinned station, filtering arrivals to one
    /// direction. Multiple destinations in the same physical direction
    /// (Forest Park + UIC-Halsted on the Blue Line) can be selected
    /// together; `nil` means "all destinations at this station, both
    /// directions." Cleared whenever `pinnedLine` or `pinnedStationId`
    /// changes.
    ///
    /// Legacy payloads stored a single `String?` under the same key; the
    /// custom decoder accepts either shape and wraps a single string
    /// into a one-element array.
    public var pinnedTrainDestinations: [String]?
    /// User has explicitly pinned a CTA bus route (e.g. "22", "X9", "147").
    /// When set, the refresh path fetches predictions at the nearest stop on
    /// that route. Optional MapKit-suggested route fills this in too.
    public var pinnedBusRoute: String?
    /// Direction label ("Northbound", "Eastbound", …) the user picked for
    /// the pinned bus route. Cleared whenever `pinnedBusRoute` changes.
    public var pinnedBusDirection: String?
    /// Specific CTA bus stop id the user chose on the pinned route. When nil,
    /// the dashboard auto-picks the nearest stop for `pinnedBusDirection`.
    /// Cleared whenever `pinnedBusRoute` or `pinnedBusDirection` changes.
    public var pinnedBusStopId: Int?
    /// User has explicitly pinned a Metra line (for example "BNSF" or
    /// "UP-N"). The refresh path surfaces the nearest station on that line.
    public var pinnedMetraRoute: String?
    /// Specific Metra station id on the pinned route. When nil, the dashboard
    /// picks the nearest station on `pinnedMetraRoute`.
    public var pinnedMetraStationId: String?
    /// Optional GTFS direction id for the pinned Metra route/station.
    public var pinnedMetraDirectionId: Int?
    /// Destination/headsign label for the pinned Metra direction.
    public var pinnedMetraDestination: String?
    /// Whether the dashboard should surface Northwestern Intercampus
    /// arrivals near the user's current location.
    public var includeIntercampus: Bool
    /// Direction currently selected in the dashboard Intercampus card.
    public var pinnedIntercampusDirection: IntercampusDirection?
    /// Specific TripShot stop id selected in the Intercampus card.
    public var pinnedIntercampusStopId: String?
    /// User-controlled override for the 30 s foreground refresh ticker. When
    /// off, the app falls back to pull-to-refresh + background tasks (which
    /// run every 15–45 min depending on commute window). iOS Low Power Mode
    /// overrides this to off regardless of the user setting.
    public var liveUpdatesEnabled: Bool
    /// When enabled, the app may replace stale pins with an on-device commute
    /// prediction. Manual pins block this for a short override window.
    public var autopinEnabled: Bool
    /// When enabled, the app records coarse GPS samples during cycling
    /// sessions so it can learn the user's habitual bike routes.
    /// Default off; iOS Low Power Mode overrides to off regardless of
    /// this setting. Tier 2 of Phase 5b; samples persist locally only.
    public var bikeRouteLearningEnabled: Bool
    /// When enabled, the dashboard shows the "Near you" discovery
    /// surface AND the refresh path queries nearby trains / buses /
    /// Metra in addition to the user's pinned routes. Default off so
    /// new installs (and existing users on first encounter with this
    /// release) don't pay the discovery-fetch cost until they ask for
    /// it. Toggleable from Settings or via the inline "Show nearby"
    /// button on the dashboard.
    public var nearbyDiscoveryEnabled: Bool
    /// Records whether the current pinned line / bus route came from the user
    /// or the local commute predictor.
    public var pinSource: RoutePinSource
    /// Last time the user directly changed a train or bus pin.
    public var lastManualPinAt: Date?
    /// Last time the local predictor changed the pin.
    public var lastAutoPinAt: Date?
    /// Direction the current automatic pin is intended to surface.
    public var autoPinnedDirection: CommuteDirection?
    /// A trip-level pin created from a planned route. This can point at
    /// transfer stops that are not near the user yet, so widgets and Live
    /// Activities should prefer it over generic route pins.
    public var plannedTripPin: PlannedTripPin?

    public init(
        trains: [TrainPreference] = [],
        buses: [BusPreference] = [],
        metra: [MetraPreference] = [],
        includeFreeFloatingBikes: Bool = true,
        hiddenModes: Set<TransitVisibilityMode> = [],
        hiddenTrainLines: Set<LineColor> = [],
        hiddenBusRoutes: Set<String> = [],
        hiddenMetraRoutes: Set<String> = [],
        autoStartLiveActivity: Bool = true,
        alwaysShowLiveActivity: Bool = true,
        pinnedLine: LineColor? = nil,
        pinnedStationId: Int? = nil,
        pinnedTrainDestinations: [String]? = nil,
        pinnedBusRoute: String? = nil,
        pinnedBusDirection: String? = nil,
        pinnedBusStopId: Int? = nil,
        pinnedMetraRoute: String? = nil,
        pinnedMetraStationId: String? = nil,
        pinnedMetraDirectionId: Int? = nil,
        pinnedMetraDestination: String? = nil,
        includeIntercampus: Bool = false,
        pinnedIntercampusDirection: IntercampusDirection? = nil,
        pinnedIntercampusStopId: String? = nil,
        liveUpdatesEnabled: Bool = true,
        autopinEnabled: Bool = true,
        bikeRouteLearningEnabled: Bool = false,
        nearbyDiscoveryEnabled: Bool = false,
        pinSource: RoutePinSource = .manual,
        lastManualPinAt: Date? = nil,
        lastAutoPinAt: Date? = nil,
        autoPinnedDirection: CommuteDirection? = nil,
        plannedTripPin: PlannedTripPin? = nil
    ) {
        self.trains = trains
        self.buses = buses
        self.metra = metra
        self.includeFreeFloatingBikes = includeFreeFloatingBikes
        self.hiddenModes = hiddenModes
        self.hiddenTrainLines = hiddenTrainLines
        self.hiddenBusRoutes = hiddenBusRoutes
        self.hiddenMetraRoutes = hiddenMetraRoutes
        self.autoStartLiveActivity = autoStartLiveActivity
        self.alwaysShowLiveActivity = alwaysShowLiveActivity
        self.pinnedLine = pinnedLine
        self.pinnedStationId = pinnedStationId
        self.pinnedTrainDestinations = pinnedTrainDestinations
        self.pinnedBusRoute = pinnedBusRoute
        self.pinnedBusDirection = pinnedBusDirection
        self.pinnedBusStopId = pinnedBusStopId
        self.pinnedMetraRoute = pinnedMetraRoute
        self.pinnedMetraStationId = pinnedMetraStationId
        self.pinnedMetraDirectionId = pinnedMetraDirectionId
        self.pinnedMetraDestination = pinnedMetraDestination
        self.includeIntercampus = includeIntercampus
        self.pinnedIntercampusDirection = pinnedIntercampusDirection
        self.pinnedIntercampusStopId = pinnedIntercampusStopId
        self.liveUpdatesEnabled = liveUpdatesEnabled
        self.autopinEnabled = autopinEnabled
        self.bikeRouteLearningEnabled = bikeRouteLearningEnabled
        self.nearbyDiscoveryEnabled = nearbyDiscoveryEnabled
        self.pinSource = pinSource
        self.lastManualPinAt = lastManualPinAt
        self.lastAutoPinAt = lastAutoPinAt
        self.autoPinnedDirection = autoPinnedDirection
        self.plannedTripPin = plannedTripPin
    }

    // Custom decoder so adding new fields stays backwards-compatible with
    /// Read-only legacy key for the pre-grouping single-destination
    /// payload. Kept in a separate enum so the auto-synthesized
    /// encoder doesn't try to write it.
    private enum LegacyCodingKeys: String, CodingKey {
        case pinnedTrainDestination
    }

    // preferences blobs already on disk from older app versions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
        self.trains = (try? c.decode([TrainPreference].self, forKey: .trains)) ?? []
        self.buses = (try? c.decode([BusPreference].self, forKey: .buses)) ?? []
        self.metra = (try? c.decode([MetraPreference].self, forKey: .metra)) ?? []
        self.includeFreeFloatingBikes = (try? c.decode(Bool.self, forKey: .includeFreeFloatingBikes)) ?? true
        self.hiddenModes = (try? c.decode(Set<TransitVisibilityMode>.self, forKey: .hiddenModes)) ?? []
        self.hiddenTrainLines = (try? c.decode(Set<LineColor>.self, forKey: .hiddenTrainLines)) ?? []
        self.hiddenBusRoutes = (try? c.decode(Set<String>.self, forKey: .hiddenBusRoutes)) ?? []
        self.hiddenMetraRoutes = (try? c.decode(Set<String>.self, forKey: .hiddenMetraRoutes)) ?? []
        self.autoStartLiveActivity = (try? c.decode(Bool.self, forKey: .autoStartLiveActivity)) ?? true
        self.alwaysShowLiveActivity = (try? c.decode(Bool.self, forKey: .alwaysShowLiveActivity)) ?? true
        self.pinnedLine = try? c.decode(LineColor.self, forKey: .pinnedLine)
        self.pinnedStationId = try? c.decode(Int.self, forKey: .pinnedStationId)
        // Backward-compat: legacy payloads stored a single `String?`
        // under `.pinnedTrainDestination` (singular). New writes use
        // `[String]?` under `.pinnedTrainDestinations`. Try the new
        // key first, fall back to the legacy single string wrapped
        // in a one-element array.
        if let array = try? c.decode([String].self, forKey: .pinnedTrainDestinations) {
            self.pinnedTrainDestinations = array
        } else if let legacyDest = try? legacy?.decode(String.self, forKey: .pinnedTrainDestination) {
            self.pinnedTrainDestinations = [legacyDest]
        } else {
            self.pinnedTrainDestinations = nil
        }
        self.pinnedBusRoute = try? c.decode(String.self, forKey: .pinnedBusRoute)
        self.pinnedBusDirection = try? c.decode(String.self, forKey: .pinnedBusDirection)
        self.pinnedBusStopId = try? c.decode(Int.self, forKey: .pinnedBusStopId)
        self.pinnedMetraRoute = try? c.decode(String.self, forKey: .pinnedMetraRoute)
        self.pinnedMetraStationId = try? c.decode(String.self, forKey: .pinnedMetraStationId)
        self.pinnedMetraDirectionId = try? c.decode(Int.self, forKey: .pinnedMetraDirectionId)
        self.pinnedMetraDestination = try? c.decode(String.self, forKey: .pinnedMetraDestination)
        self.includeIntercampus = (try? c.decode(Bool.self, forKey: .includeIntercampus)) ?? false
        self.pinnedIntercampusDirection = try? c.decode(IntercampusDirection.self, forKey: .pinnedIntercampusDirection)
        self.pinnedIntercampusStopId = try? c.decode(String.self, forKey: .pinnedIntercampusStopId)
        self.liveUpdatesEnabled = (try? c.decode(Bool.self, forKey: .liveUpdatesEnabled)) ?? true
        self.autopinEnabled = (try? c.decode(Bool.self, forKey: .autopinEnabled)) ?? true
        self.bikeRouteLearningEnabled = (try? c.decode(Bool.self, forKey: .bikeRouteLearningEnabled)) ?? false
        self.nearbyDiscoveryEnabled = (try? c.decode(Bool.self, forKey: .nearbyDiscoveryEnabled)) ?? false
        self.pinSource = (try? c.decode(RoutePinSource.self, forKey: .pinSource)) ?? .manual
        self.lastManualPinAt = try? c.decode(Date.self, forKey: .lastManualPinAt)
        self.lastAutoPinAt = try? c.decode(Date.self, forKey: .lastAutoPinAt)
        self.autoPinnedDirection = try? c.decode(CommuteDirection.self, forKey: .autoPinnedDirection)
        self.plannedTripPin = try? c.decode(PlannedTripPin.self, forKey: .plannedTripPin)
    }

    public static let empty = UserRoutePreferences()

    public var hasPinnedTransit: Bool {
        pinnedLine != nil || pinnedBusRoute != nil || pinnedMetraRoute != nil || plannedTripPin != nil
    }

    public func isModeVisible(_ mode: TransitVisibilityMode) -> Bool {
        !hiddenModes.contains(mode)
    }

    public func isTrainLineVisible(_ line: LineColor) -> Bool {
        isModeVisible(.trains) && !hiddenTrainLines.contains(line)
    }

    public func isBusRouteVisible(_ route: String) -> Bool {
        isModeVisible(.buses) && !hiddenBusRoutes.contains(route)
    }

    public func isMetraRouteVisible(_ routeId: String) -> Bool {
        isModeVisible(.metra) && !hiddenMetraRoutes.contains(routeId)
    }

    public mutating func markManualPin(at date: Date = .now) {
        pinSource = .manual
        lastManualPinAt = date
        autoPinnedDirection = nil
    }

    public mutating func markAutomaticPin(direction: CommuteDirection, at date: Date = .now) {
        pinSource = .automatic
        lastAutoPinAt = date
        autoPinnedDirection = direction
    }

    public mutating func clearExpiredPlannedTripPin(now: Date = .now) -> Bool {
        guard let plannedTripPin, plannedTripPin.isExpired(now: now) else { return false }
        self.plannedTripPin = nil
        return true
    }
}
