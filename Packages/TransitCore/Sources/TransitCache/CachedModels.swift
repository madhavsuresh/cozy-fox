import Foundation
import SwiftData
import TransitModels

@Model
public final class CachedTrainArrival {
    @Attribute(.unique) public var id: String
    public var lineRaw: String
    public var runNumber: String
    public var destinationName: String
    public var stationId: Int
    public var stationName: String
    public var stopId: Int
    public var directionCode: String
    public var predictedAt: Date
    public var arrivalAt: Date
    public var isApproaching: Bool
    public var isDelayed: Bool
    public var isScheduled: Bool
    public var fetchedAt: Date

    public init(arrival: Arrival, fetchedAt: Date) {
        self.id = arrival.id
        self.lineRaw = arrival.line.rawValue
        self.runNumber = arrival.runNumber
        self.destinationName = arrival.destinationName
        self.stationId = arrival.stationId
        self.stationName = arrival.stationName
        self.stopId = arrival.stopId
        self.directionCode = arrival.directionCode
        self.predictedAt = arrival.predictedAt
        self.arrivalAt = arrival.arrivalAt
        self.isApproaching = arrival.isApproaching
        self.isDelayed = arrival.isDelayed
        self.isScheduled = arrival.isScheduled
        self.fetchedAt = fetchedAt
    }

    public var asModel: Arrival? {
        guard let line = LineColor(rawValue: lineRaw) else { return nil }
        return Arrival(
            id: id,
            line: line,
            runNumber: runNumber,
            destinationName: destinationName,
            stationId: stationId,
            stationName: stationName,
            stopId: stopId,
            directionCode: directionCode,
            predictedAt: predictedAt,
            arrivalAt: arrivalAt,
            isApproaching: isApproaching,
            isDelayed: isDelayed,
            isFault: false,
            isScheduled: isScheduled
        )
    }
}

@Model
public final class CachedBusPrediction {
    @Attribute(.unique) public var id: String
    public var route: String
    public var routeName: String
    public var vehicleId: String
    public var stopId: Int
    public var stopName: String
    public var destinationName: String
    public var directionName: String
    public var generatedAt: Date
    public var arrivalAt: Date
    public var isDelayed: Bool
    public var isApproaching: Bool
    public var fetchedAt: Date

    public init(prediction: BusPrediction, fetchedAt: Date) {
        self.id = prediction.id
        self.route = prediction.route
        self.routeName = prediction.routeName
        self.vehicleId = prediction.vehicleId
        self.stopId = prediction.stopId
        self.stopName = prediction.stopName
        self.destinationName = prediction.destinationName
        self.directionName = prediction.directionName
        self.generatedAt = prediction.generatedAt
        self.arrivalAt = prediction.arrivalAt
        self.isDelayed = prediction.isDelayed
        self.isApproaching = prediction.isApproaching
        self.fetchedAt = fetchedAt
    }

    public var asModel: BusPrediction {
        BusPrediction(
            id: id,
            route: route,
            routeName: routeName,
            vehicleId: vehicleId,
            stopId: stopId,
            stopName: stopName,
            destinationName: destinationName,
            directionName: directionName,
            generatedAt: generatedAt,
            arrivalAt: arrivalAt,
            isDelayed: isDelayed,
            isApproaching: isApproaching
        )
    }
}

/// One row per (stationId, snappedAt). Retained 14 days so the future
/// `EBikeChurnEstimator` can read historical depletion rates.
@Model
public final class CachedEBikeStation {
    public var stationId: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var eBikesAvailable: Int
    public var classicBikesAvailable: Int
    public var docksAvailable: Int
    public var capacity: Int
    public var isRenting: Bool
    public var isReturning: Bool
    public var snappedAt: Date

    public init(station: BikeStation, snappedAt: Date) {
        self.stationId = station.id
        self.name = station.name
        self.latitude = station.latitude
        self.longitude = station.longitude
        self.eBikesAvailable = station.eBikesAvailable
        self.classicBikesAvailable = station.classicBikesAvailable
        self.docksAvailable = station.docksAvailable
        self.capacity = station.capacity
        self.isRenting = station.isRenting
        self.isReturning = station.isReturning
        self.snappedAt = snappedAt
    }

    public var asModel: BikeStation {
        BikeStation(
            id: stationId,
            name: name,
            latitude: latitude,
            longitude: longitude,
            capacity: capacity,
            eBikesAvailable: eBikesAvailable,
            classicBikesAvailable: classicBikesAvailable,
            docksAvailable: docksAvailable,
            isRenting: isRenting,
            isReturning: isReturning,
            lastReported: snappedAt
        )
    }
}

/// Pre-computed "what to show on the dashboard / widget right now". One row per
/// rank (0 = closest), written together by `TransitStore.replaceNearbyBikePicks`.
/// The widget reads `rank == 0`; the dashboard reads all rows sorted by `rank`.
@Model
public final class CachedNearestBike {
    @Attribute(.unique) public var key: String
    public var rank: Int = 0
    public var stationId: String
    public var stationName: String
    public var latitude: Double
    public var longitude: Double
    public var eBikesAvailable: Int
    public var capacity: Int
    public var walkingDistanceMeters: Double
    public var bestRangeMeters: Double
    public var freeFloatingNearby: Int
    public var computedAt: Date

    public init(pick: NearestBikePick, rank: Int = 0) {
        self.key = "rank-\(rank)"
        self.rank = rank
        self.stationId = pick.station.id
        self.stationName = pick.station.name
        self.latitude = pick.station.latitude
        self.longitude = pick.station.longitude
        self.eBikesAvailable = pick.station.eBikesAvailable
        self.capacity = pick.station.capacity
        self.walkingDistanceMeters = pick.walkingDistanceMeters
        self.bestRangeMeters = pick.bestRangeMeters
        self.freeFloatingNearby = pick.freeFloatingNearby
        self.computedAt = pick.computedAt
    }
}

@Model
public final class CachedAlert {
    @Attribute(.unique) public var id: String
    public var headline: String
    public var shortDescription: String
    public var severityRaw: String
    public var impactedRoutes: [String]
    public var beginsAt: Date
    public var endsAt: Date?
    public var isMajor: Bool
    /// Kept as a nil-always column to avoid a destructive SwiftData migration for
    /// users who installed the previous build. The "Details" link is now a static
    /// pointer to `ServiceAlert.detailsURL` (the CTA alerts hub) since the
    /// per-alert URL the API hands out goes to a page CTA no longer renders.
    public var detailURLString: String?
    public var fetchedAt: Date

    public init(alert: ServiceAlert, fetchedAt: Date) {
        self.id = alert.id
        self.headline = alert.headline
        self.shortDescription = alert.shortDescription
        self.severityRaw = alert.severity.rawValue
        self.impactedRoutes = alert.impactedRoutes
        self.beginsAt = alert.beginsAt
        self.endsAt = alert.endsAt
        self.isMajor = alert.isMajor
        self.detailURLString = nil
        self.fetchedAt = fetchedAt
    }

    public var asModel: ServiceAlert {
        let severity = AlertSeverity(rawValue: severityRaw) ?? .low
        return ServiceAlert(
            id: id,
            headline: headline,
            shortDescription: shortDescription,
            severity: severity,
            impactedRoutes: impactedRoutes,
            impactedLineColors: impactedRoutes.compactMap { LineColor(ctaRouteCode: $0) },
            beginsAt: beginsAt,
            endsAt: endsAt,
            isMajor: isMajor
        )
    }
}
