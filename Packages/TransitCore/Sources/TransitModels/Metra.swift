import Foundation

public struct MetraLine: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let shortName: String
    public let longName: String
    public let colorHex: String
    public let textColorHex: String
    public let url: URL?

    public init(
        id: String,
        shortName: String,
        longName: String,
        colorHex: String,
        textColorHex: String,
        url: URL?
    ) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.colorHex = colorHex
        self.textColorHex = textColorHex
        self.url = url
    }

    public var displayName: String {
        longName.isEmpty ? shortName : "\(shortName) · \(longName)"
    }

    public var hex: UInt32 {
        UInt32(colorHex, radix: 16) ?? 0x004B8D
    }

    public var textHex: UInt32 {
        UInt32(textColorHex, radix: 16) ?? 0xFFFFFF
    }
}

public struct MetraStation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let zoneId: String?
    public let url: URL?
    public let servedRoutes: [String]

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        zoneId: String?,
        url: URL?,
        servedRoutes: [String]
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.zoneId = zoneId
        self.url = url
        self.servedRoutes = servedRoutes
    }
}

public struct MetraPrediction: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let routeId: String
    public let routeShortName: String
    public let tripId: String
    public let trainNumber: String
    public let stationId: String
    public let stationName: String
    public let destinationName: String
    public let directionId: Int?
    public let generatedAt: Date
    public let scheduledAt: Date
    public let arrivalAt: Date
    public let delaySeconds: Int?
    public let isDelayed: Bool
    public let isCanceled: Bool
    public let isScheduled: Bool

    public init(
        id: String,
        routeId: String,
        routeShortName: String,
        tripId: String,
        trainNumber: String,
        stationId: String,
        stationName: String,
        destinationName: String,
        directionId: Int?,
        generatedAt: Date,
        scheduledAt: Date,
        arrivalAt: Date,
        delaySeconds: Int?,
        isDelayed: Bool,
        isCanceled: Bool,
        isScheduled: Bool
    ) {
        self.id = id
        self.routeId = routeId
        self.routeShortName = routeShortName
        self.tripId = tripId
        self.trainNumber = trainNumber
        self.stationId = stationId
        self.stationName = stationName
        self.destinationName = destinationName
        self.directionId = directionId
        self.generatedAt = generatedAt
        self.scheduledAt = scheduledAt
        self.arrivalAt = arrivalAt
        self.delaySeconds = delaySeconds
        self.isDelayed = isDelayed
        self.isCanceled = isCanceled
        self.isScheduled = isScheduled
    }

    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }

    public func applying(_ update: MetraRealtimeUpdate) -> MetraPrediction {
        let realtimeArrival = update.departureAt ?? update.arrivalAt ?? arrivalAt
        let delay = update.delaySeconds
            ?? Int(realtimeArrival.timeIntervalSince(scheduledAt).rounded())
        return MetraPrediction(
            id: id,
            routeId: routeId,
            routeShortName: routeShortName,
            tripId: tripId,
            trainNumber: update.vehicleLabel ?? trainNumber,
            stationId: stationId,
            stationName: stationName,
            destinationName: destinationName,
            directionId: update.directionId ?? directionId,
            generatedAt: update.generatedAt,
            scheduledAt: scheduledAt,
            arrivalAt: realtimeArrival,
            delaySeconds: delay,
            isDelayed: abs(delay) >= 60,
            isCanceled: update.scheduleRelationship == .canceled,
            isScheduled: false
        )
    }
}

public struct MetraRealtimeUpdate: Codable, Sendable, Hashable {
    public enum ScheduleRelationship: String, Codable, Sendable, Hashable {
        case scheduled
        case added
        case unscheduled
        case canceled
        case skipped
        case unknown
    }

    public let tripId: String
    public let routeId: String?
    public let directionId: Int?
    public let stopId: String
    public let arrivalAt: Date?
    public let departureAt: Date?
    public let delaySeconds: Int?
    public let vehicleId: String?
    public let vehicleLabel: String?
    public let scheduleRelationship: ScheduleRelationship
    public let generatedAt: Date

    public init(
        tripId: String,
        routeId: String?,
        directionId: Int?,
        stopId: String,
        arrivalAt: Date?,
        departureAt: Date?,
        delaySeconds: Int?,
        vehicleId: String?,
        vehicleLabel: String?,
        scheduleRelationship: ScheduleRelationship,
        generatedAt: Date
    ) {
        self.tripId = tripId
        self.routeId = routeId
        self.directionId = directionId
        self.stopId = stopId
        self.arrivalAt = arrivalAt
        self.departureAt = departureAt
        self.delaySeconds = delaySeconds
        self.vehicleId = vehicleId
        self.vehicleLabel = vehicleLabel
        self.scheduleRelationship = scheduleRelationship
        self.generatedAt = generatedAt
    }
}

public enum MetraChicagoDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case toChicago
    case fromChicago

    public var label: String {
        switch self {
        case .toChicago: "To Chicago"
        case .fromChicago: "From Chicago"
        }
    }

    var sortOrder: Int {
        switch self {
        case .toChicago: 0
        case .fromChicago: 1
        }
    }
}

public struct MetraDepartureGroup: Sendable, Hashable, Identifiable {
    public let routeId: String
    public let stationId: String
    public let directionId: Int?
    public let direction: MetraChicagoDirection
    public let terminalSummary: String?
    public let departures: [MetraPrediction]

    public init(
        routeId: String,
        stationId: String,
        directionId: Int?,
        direction: MetraChicagoDirection,
        terminalSummary: String?,
        departures: [MetraPrediction]
    ) {
        self.routeId = routeId
        self.stationId = stationId
        self.directionId = directionId
        self.direction = direction
        self.terminalSummary = terminalSummary
        self.departures = departures
    }

    public var id: String {
        "\(routeId)-\(stationId)-\(directionId.map(String.init) ?? direction.rawValue)"
    }

    public var title: String {
        direction.label
    }

    public var nextDepartureAt: Date? {
        departures.first?.arrivalAt
    }
}

public enum MetraDepartureGrouper {
    public static func groups(
        from predictions: [MetraPrediction],
        limitPerGroup: Int = 3
    ) -> [MetraDepartureGroup] {
        let sorted = predictions.sorted { $0.arrivalAt < $1.arrivalAt }
        let buckets = Dictionary(grouping: sorted) { prediction in
            direction(for: prediction.directionId, destinationName: prediction.destinationName)
        }

        return buckets.map { direction, departures in
            let limited = Array(departures.prefix(limitPerGroup))
            let routeId = limited.first?.routeId ?? departures.first?.routeId ?? ""
            let stationId = limited.first?.stationId ?? departures.first?.stationId ?? ""
            let directionIds = Set(departures.compactMap(\.directionId))
            let directionId = directionIds.count == 1 ? directionIds.first : nil
            return MetraDepartureGroup(
                routeId: routeId,
                stationId: stationId,
                directionId: directionId,
                direction: direction,
                terminalSummary: terminalSummary(for: limited),
                departures: limited
            )
        }
        .sorted(by: compareGroups)
    }

    public static func direction(
        for directionId: Int?,
        destinationName: String
    ) -> MetraChicagoDirection {
        if directionId == 1 { return .toChicago }
        if directionId == 0 { return .fromChicago }
        return chicagoTerminalNames.contains(normalizedKey(destinationName)) ? .toChicago : .fromChicago
    }

    public static func displayDestinationName(_ name: String) -> String {
        switch normalizedKey(name) {
        case "chicago union station": "Union Station"
        case "chicago otc": "Ogilvie"
        case "lasalle street": "LaSalle Street"
        case "millennium station": "Millennium"
        default: name
        }
    }

    public static func terminalSummary(
        for predictions: [MetraPrediction],
        maximumDestinations: Int = 3
    ) -> String? {
        var seen: Set<String> = []
        let names = predictions.compactMap { prediction -> String? in
            let display = displayDestinationName(prediction.destinationName)
            guard !display.isEmpty, seen.insert(display).inserted else { return nil }
            return display
        }
        guard !names.isEmpty else { return nil }
        let clipped = Array(names.prefix(maximumDestinations))
        return clipped.joined(separator: " / ")
    }

    private static func compareGroups(_ left: MetraDepartureGroup, _ right: MetraDepartureGroup) -> Bool {
        switch (left.nextDepartureAt, right.nextDepartureAt) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return left.direction.sortOrder < right.direction.sortOrder
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let chicagoTerminalNames: Set<String> = [
        "chicago union station",
        "chicago otc",
        "lasalle street",
        "millennium station"
    ]
}

public struct MetraDirectionChoice: Sendable, Hashable, Identifiable {
    public let routeId: String
    public let directionId: Int?
    public let destinationName: String
    public let nextDepartureAt: Date?

    public init(
        routeId: String,
        directionId: Int?,
        destinationName: String,
        nextDepartureAt: Date? = nil
    ) {
        self.routeId = routeId
        self.directionId = directionId
        self.destinationName = destinationName
        self.nextDepartureAt = nextDepartureAt
    }

    public var id: String {
        "\(routeId)-\(directionId.map(String.init) ?? "any")-\(destinationName)"
    }

    public var label: String {
        guard let nextDepartureAt else { return "→ \(destinationName)" }
        return "→ \(destinationName), \(MetraDepartureFormatter.timeString(nextDepartureAt))"
    }
}

public enum MetraDepartureFormatter {
    public static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    public static func accessibilityString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
