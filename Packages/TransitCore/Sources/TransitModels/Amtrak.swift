import Foundation

public enum AmtrakRouteKind: Int, Codable, Sendable, Hashable {
    case rail = 2
    case bus = 3
    case other = 0

    public var label: String {
        switch self {
        case .rail: "Rail"
        case .bus: "Thruway"
        case .other: "Amtrak"
        }
    }
}

public struct AmtrakRoute: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let shortName: String
    public let longName: String
    public let kind: AmtrakRouteKind
    public let url: URL?
    public let colorHex: String
    public let textColorHex: String

    public init(
        id: String,
        shortName: String,
        longName: String,
        kind: AmtrakRouteKind,
        url: URL?,
        colorHex: String,
        textColorHex: String
    ) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.kind = kind
        self.url = url
        self.colorHex = colorHex
        self.textColorHex = textColorHex
    }

    public var displayName: String {
        if !longName.isEmpty { return longName }
        if !shortName.isEmpty { return shortName }
        return "Amtrak \(id)"
    }

    public var displayCode: String {
        if !shortName.isEmpty { return shortName }
        let words = displayName
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        let initials = words
            .filter { !["amtrak", "service", "connecting", "the"].contains($0.lowercased()) }
            .prefix(3)
            .compactMap(\.first)
        let code = String(initials).uppercased()
        return code.isEmpty ? "ATK" : code
    }

    public var hex: UInt32 {
        UInt32(colorHex, radix: 16) ?? 0x005DAA
    }

    public var textHex: UInt32 {
        UInt32(textColorHex, radix: 16) ?? 0xFFFFFF
    }
}

public struct AmtrakStation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let url: URL?
    public let timeZoneIdentifier: String?
    public let latitude: Double
    public let longitude: Double
    public let servedRoutes: [String]

    public init(
        id: String,
        name: String,
        url: URL?,
        timeZoneIdentifier: String?,
        latitude: Double,
        longitude: Double,
        servedRoutes: [String]
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.timeZoneIdentifier = timeZoneIdentifier
        self.latitude = latitude
        self.longitude = longitude
        self.servedRoutes = servedRoutes
    }
}

public struct AmtrakPrediction: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let routeId: String
    public let routeName: String
    public let routeKind: AmtrakRouteKind
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
    public let sourceLabel: String

    public init(
        id: String,
        routeId: String,
        routeName: String,
        routeKind: AmtrakRouteKind,
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
        isScheduled: Bool,
        sourceLabel: String
    ) {
        self.id = id
        self.routeId = routeId
        self.routeName = routeName
        self.routeKind = routeKind
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
        self.sourceLabel = sourceLabel
    }

    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }

    public func applying(_ update: AmtrakRealtimeUpdate) -> AmtrakPrediction {
        let realtimeArrival = update.departureAt ?? update.arrivalAt ?? arrivalAt
        let delay = update.delaySeconds
            ?? Int(realtimeArrival.timeIntervalSince(scheduledAt).rounded())
        return AmtrakPrediction(
            id: id,
            routeId: routeId,
            routeName: routeName,
            routeKind: routeKind,
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
            isScheduled: false,
            sourceLabel: "Live status"
        )
    }
}

public struct AmtrakRealtimeUpdate: Codable, Sendable, Hashable {
    public enum ScheduleRelationship: String, Codable, Sendable, Hashable {
        case scheduled
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
        self.vehicleLabel = vehicleLabel
        self.scheduleRelationship = scheduleRelationship
        self.generatedAt = generatedAt
    }
}

public struct AmtrakDepartureGroup: Sendable, Hashable, Identifiable {
    public let routeId: String
    public let title: String
    public let directionId: Int?
    public let departures: [AmtrakPrediction]

    public var id: String { "\(routeId)-\(directionId.map(String.init) ?? title)" }
    public var nextDepartureAt: Date? { departures.first?.arrivalAt }
}

public enum AmtrakDepartureGrouper {
    public static func groups(
        from predictions: [AmtrakPrediction],
        limitPerGroup: Int = 3
    ) -> [AmtrakDepartureGroup] {
        let grouped = Dictionary(grouping: predictions) { prediction in
            "\(prediction.routeId)|\(prediction.directionId.map(String.init) ?? prediction.destinationName)"
        }
        return grouped.values.compactMap { group in
            guard let first = group.sorted(by: { $0.arrivalAt < $1.arrivalAt }).first else { return nil }
            let departures = Array(group.sorted { $0.arrivalAt < $1.arrivalAt }.prefix(limitPerGroup))
            return AmtrakDepartureGroup(
                routeId: first.routeId,
                title: first.destinationName.isEmpty ? first.routeName : first.destinationName,
                directionId: first.directionId,
                departures: departures
            )
        }
        .sorted {
            ($0.nextDepartureAt ?? .distantFuture) < ($1.nextDepartureAt ?? .distantFuture)
        }
    }
}

public struct AmtrakDirectionChoice: Sendable, Hashable, Identifiable {
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
        return "→ \(destinationName), \(AmtrakDepartureFormatter.timeString(nextDepartureAt))"
    }
}

public enum AmtrakDepartureFormatter {
    public static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    public static func accessibilityString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
