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
