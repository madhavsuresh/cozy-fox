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
    public var isFault: Bool = false
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
        self.isFault = arrival.isFault
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
            isFault: isFault,
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

@Model
public final class CachedMetraPrediction {
    @Attribute(.unique) public var id: String
    public var routeId: String
    public var routeShortName: String
    public var tripId: String
    public var trainNumber: String
    public var stationId: String
    public var stationName: String
    public var destinationName: String
    public var directionId: Int?
    public var generatedAt: Date
    public var scheduledAt: Date
    public var arrivalAt: Date
    public var delaySeconds: Int?
    public var isDelayed: Bool
    public var isCanceled: Bool
    public var isScheduled: Bool
    public var fetchedAt: Date

    public init(prediction: MetraPrediction, fetchedAt: Date) {
        self.id = prediction.id
        self.routeId = prediction.routeId
        self.routeShortName = prediction.routeShortName
        self.tripId = prediction.tripId
        self.trainNumber = prediction.trainNumber
        self.stationId = prediction.stationId
        self.stationName = prediction.stationName
        self.destinationName = prediction.destinationName
        self.directionId = prediction.directionId
        self.generatedAt = prediction.generatedAt
        self.scheduledAt = prediction.scheduledAt
        self.arrivalAt = prediction.arrivalAt
        self.delaySeconds = prediction.delaySeconds
        self.isDelayed = prediction.isDelayed
        self.isCanceled = prediction.isCanceled
        self.isScheduled = prediction.isScheduled
        self.fetchedAt = fetchedAt
    }

    public var asModel: MetraPrediction {
        MetraPrediction(
            id: id,
            routeId: routeId,
            routeShortName: routeShortName,
            tripId: tripId,
            trainNumber: trainNumber,
            stationId: stationId,
            stationName: stationName,
            destinationName: destinationName,
            directionId: directionId,
            generatedAt: generatedAt,
            scheduledAt: scheduledAt,
            arrivalAt: arrivalAt,
            delaySeconds: delaySeconds,
            isDelayed: isDelayed,
            isCanceled: isCanceled,
            isScheduled: isScheduled
        )
    }
}

@Model
public final class CachedVehiclePosition {
    @Attribute(.unique) public var key: String
    public var vehicleId: String
    public var modeRaw: String
    public var route: String
    public var latitude: Double
    public var longitude: Double
    public var heading: Int?
    public var destinationName: String?
    public var nextStopId: Int?
    /// CTA `pid` — bus pattern variant the vehicle is currently running.
    /// Default nil so the new field is backwards-compatible with cached
    /// rows that predate phase 3.
    public var patternId: Int?
    /// CTA `pdist` — along-pattern distance in feet.
    public var patternDistanceFeet: Double?
    public var observedAt: Date
    public var fetchedAt: Date

    public init(position: VehiclePosition, fetchedAt: Date) {
        self.key = "\(position.mode.rawValue)-\(position.route)-\(position.id)"
        self.vehicleId = position.id
        self.modeRaw = position.mode.rawValue
        self.route = position.route
        self.latitude = position.latitude
        self.longitude = position.longitude
        self.heading = position.heading
        self.destinationName = position.destinationName
        self.nextStopId = position.nextStopId
        self.patternId = position.patternId
        self.patternDistanceFeet = position.patternDistanceFeet
        self.observedAt = position.observedAt
        self.fetchedAt = fetchedAt
    }

    public var asModel: VehiclePosition? {
        guard let mode = VehiclePosition.Mode(rawValue: modeRaw) else { return nil }
        return VehiclePosition(
            id: vehicleId,
            mode: mode,
            route: route,
            latitude: latitude,
            longitude: longitude,
            heading: heading,
            destinationName: destinationName,
            nextStopId: nextStopId,
            patternId: patternId,
            patternDistanceFeet: patternDistanceFeet,
            observedAt: observedAt
        )
    }
}

@Model
public final class CachedBusPattern {
    @Attribute(.unique) public var id: Int
    public var route: String
    public var directionName: String
    public var lengthFeet: Double?
    public var detourId: String?
    /// `[BusPatternPoint]` serialized as JSON. SwiftData persists arrays of
    /// primitives, not arrays of nested structs, so points round-trip
    /// through `JSONEncoder`/`Decoder`.
    public var pointsJSON: String
    public var fetchedAt: Date

    public init(pattern: BusPattern, fetchedAt: Date) {
        self.id = pattern.id
        self.route = pattern.route
        self.directionName = pattern.directionName
        self.lengthFeet = pattern.lengthFeet
        self.detourId = pattern.detourId
        self.pointsJSON = (try? String(
            data: JSONEncoder().encode(pattern.points),
            encoding: .utf8
        )) ?? "[]"
        self.fetchedAt = fetchedAt
    }

    public var asModel: BusPattern {
        let points: [BusPatternPoint] = (try? JSONDecoder().decode(
            [BusPatternPoint].self,
            from: Data(pointsJSON.utf8)
        )) ?? []
        return BusPattern(
            id: id,
            route: route,
            directionName: directionName,
            lengthFeet: lengthFeet,
            detourId: detourId,
            points: points
        )
    }
}

@Model
public final class CachedIntercampusArrival {
    @Attribute(.unique) public var id: String
    public var routeId: String
    public var directionRaw: String
    public var tripId: String
    public var vehicleId: String?
    public var vehicleLabel: String?
    public var stopId: String
    public var stopName: String
    public var destinationName: String
    public var generatedAt: Date
    public var arrivalAt: Date
    public var delaySeconds: Int?
    public var isDelayed: Bool
    public var timeSourceRaw: String?
    public var vehicleLatitude: Double?
    public var vehicleLongitude: Double?
    public var vehicleHeading: Int?
    public var vehicleObservedAt: Date?
    public var trafficGeneratedAt: Date?
    public var trafficSourceArrivalAt: Date?
    public var trafficArrivalAt: Date?
    public var trafficTravelTime: TimeInterval?
    public var trafficDistanceMeters: Double?
    public var fetchedAt: Date

    public init(arrival: IntercampusArrival, fetchedAt: Date) {
        self.id = arrival.id
        self.routeId = arrival.routeId
        self.directionRaw = arrival.direction.rawValue
        self.tripId = arrival.tripId
        self.vehicleId = arrival.vehicleId
        self.vehicleLabel = arrival.vehicleLabel
        self.stopId = arrival.stopId
        self.stopName = arrival.stopName
        self.destinationName = arrival.destinationName
        self.generatedAt = arrival.generatedAt
        self.arrivalAt = arrival.arrivalAt
        self.delaySeconds = arrival.delaySeconds
        self.isDelayed = arrival.isDelayed
        self.timeSourceRaw = arrival.timeSource.rawValue
        self.vehicleLatitude = arrival.vehicleLocation?.latitude
        self.vehicleLongitude = arrival.vehicleLocation?.longitude
        self.vehicleHeading = arrival.vehicleLocation?.heading
        self.vehicleObservedAt = arrival.vehicleLocation?.observedAt
        self.trafficGeneratedAt = arrival.trafficEstimate?.generatedAt
        self.trafficSourceArrivalAt = arrival.trafficEstimate?.sourceArrivalAt
        self.trafficArrivalAt = arrival.trafficEstimate?.arrivalAt
        self.trafficTravelTime = arrival.trafficEstimate?.travelTime
        self.trafficDistanceMeters = arrival.trafficEstimate?.distanceMeters
        self.fetchedAt = fetchedAt
    }

    public var asModel: IntercampusArrival? {
        guard let direction = IntercampusDirection(rawValue: directionRaw) else { return nil }
        let fallbackSource: IntercampusArrivalTimeSource = id.hasPrefix("intercampus-scheduled-")
            ? .schedule
            : .liveMap
        let timeSource = timeSourceRaw
            .flatMap(IntercampusArrivalTimeSource.init(rawValue:)) ?? fallbackSource
        let vehicleLocation: IntercampusVehicleLocation?
        if let vehicleLatitude, let vehicleLongitude, let vehicleObservedAt {
            vehicleLocation = IntercampusVehicleLocation(
                id: vehicleId,
                label: vehicleLabel,
                latitude: vehicleLatitude,
                longitude: vehicleLongitude,
                heading: vehicleHeading,
                observedAt: vehicleObservedAt
            )
        } else {
            vehicleLocation = nil
        }
        let trafficEstimate: IntercampusTrafficEstimate?
        if let trafficGeneratedAt,
           let trafficSourceArrivalAt,
           let trafficArrivalAt,
           let trafficTravelTime,
           let trafficDistanceMeters
        {
            trafficEstimate = IntercampusTrafficEstimate(
                generatedAt: trafficGeneratedAt,
                sourceArrivalAt: trafficSourceArrivalAt,
                arrivalAt: trafficArrivalAt,
                travelTime: trafficTravelTime,
                distanceMeters: trafficDistanceMeters
            )
        } else {
            trafficEstimate = nil
        }
        return IntercampusArrival(
            id: id,
            routeId: routeId,
            direction: direction,
            tripId: tripId,
            vehicleId: vehicleId,
            vehicleLabel: vehicleLabel,
            stopId: stopId,
            stopName: stopName,
            destinationName: destinationName,
            generatedAt: generatedAt,
            arrivalAt: arrivalAt,
            delaySeconds: delaySeconds,
            isDelayed: isDelayed,
            timeSource: timeSource,
            vehicleLocation: vehicleLocation,
            trafficEstimate: trafficEstimate
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
    public var dockedBikesJSON: String?
    public var freeFloatingNearby: Int
    public var freeFloatingBikesJSON: String?
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
        if let data = try? JSONEncoder().encode(pick.dockedBikes) {
            self.dockedBikesJSON = String(data: data, encoding: .utf8)
        } else {
            self.dockedBikesJSON = nil
        }
        self.freeFloatingNearby = pick.freeFloatingNearby
        if let data = try? JSONEncoder().encode(pick.nearbyFreeFloatingBikes) {
            self.freeFloatingBikesJSON = String(data: data, encoding: .utf8)
        } else {
            self.freeFloatingBikesJSON = nil
        }
        self.computedAt = pick.computedAt
    }
}

@Model
public final class CachedNearestFreeBike {
    @Attribute(.unique) public var key: String
    public var rank: Int = 0
    public var bikeId: String
    public var latitude: Double
    public var longitude: Double
    public var currentRangeMeters: Double
    public var walkingDistanceMeters: Double
    public var computedAt: Date

    public init(pick: NearestFreeBikePick, rank: Int = 0) {
        self.key = "free-rank-\(rank)"
        self.rank = rank
        self.bikeId = pick.bike.id
        self.latitude = pick.bike.latitude
        self.longitude = pick.bike.longitude
        self.currentRangeMeters = pick.bike.currentRangeMeters
        self.walkingDistanceMeters = pick.walkingDistanceMeters
        self.computedAt = pick.computedAt
    }

    public var asModel: NearestFreeBikePick {
        NearestFreeBikePick(
            bike: EBike(
                id: bikeId,
                latitude: latitude,
                longitude: longitude,
                currentRangeMeters: currentRangeMeters,
                isReserved: false,
                isDisabled: false,
                stationId: nil
            ),
            walkingDistanceMeters: walkingDistanceMeters,
            computedAt: computedAt
        )
    }
}

@Model
public final class CachedBusDetour {
    @Attribute(.unique) public var id: String
    public var version: Int
    public var isActive: Bool
    public var summary: String
    /// `[BusDetour.RouteDirection]` serialized as JSON. SwiftData persists
    /// arrays of primitive types but not arrays of nested structs, so we
    /// encode here and decode in `asModel`.
    public var affectedJSON: String
    public var beginsAt: Date?
    public var endsAt: Date?
    public var fetchedAt: Date

    public init(detour: BusDetour, fetchedAt: Date) {
        self.id = detour.id
        self.version = detour.version
        self.isActive = detour.isActive
        self.summary = detour.summary
        self.affectedJSON = (try? String(
            data: JSONEncoder().encode(detour.affected),
            encoding: .utf8
        )) ?? "[]"
        self.beginsAt = detour.beginsAt
        self.endsAt = detour.endsAt
        self.fetchedAt = fetchedAt
    }

    public var asModel: BusDetour {
        let affected: [BusDetour.RouteDirection] = (try? JSONDecoder().decode(
            [BusDetour.RouteDirection].self,
            from: Data(affectedJSON.utf8)
        )) ?? []
        return BusDetour(
            id: id,
            version: version,
            isActive: isActive,
            summary: summary,
            affected: affected,
            beginsAt: beginsAt,
            endsAt: endsAt
        )
    }
}

@Model
public final class CachedBusPredictionResidual {
    @Attribute(.unique) public var id: UUID
    public var route: String
    public var directionName: String
    public var stopId: Int
    public var vehicleId: String
    public var predictedAt: Date
    public var predictedArrivalAt: Date
    public var confirmedArrivalAt: Date
    public var horizonBucketRaw: String
    public var hourOfWeek: Int
    public var residualSeconds: Double

    public init(residual: BusPredictionResidual) {
        self.id = residual.id
        self.route = residual.route
        self.directionName = residual.directionName
        self.stopId = residual.stopId
        self.vehicleId = residual.vehicleId
        self.predictedAt = residual.predictedAt
        self.predictedArrivalAt = residual.predictedArrivalAt
        self.confirmedArrivalAt = residual.confirmedArrivalAt
        self.horizonBucketRaw = residual.horizonBucket.rawValue
        self.hourOfWeek = residual.hourOfWeek
        self.residualSeconds = residual.residualSeconds
    }

    public var asModel: BusPredictionResidual? {
        guard let bucket = BusHorizonBucket(rawValue: horizonBucketRaw) else { return nil }
        return BusPredictionResidual(
            id: id,
            route: route,
            directionName: directionName,
            stopId: stopId,
            vehicleId: vehicleId,
            predictedAt: predictedAt,
            predictedArrivalAt: predictedArrivalAt,
            confirmedArrivalAt: confirmedArrivalAt,
            horizonBucket: bucket,
            hourOfWeek: hourOfWeek,
            residualSeconds: residualSeconds
        )
    }
}

@Model
public final class CachedBusResidualQuantileBin {
    /// Composite primary key — `BusResidualQuantileBin.key`.
    @Attribute(.unique) public var key: String
    public var route: String
    public var directionName: String
    public var stopId: Int
    public var horizonBucketRaw: String
    public var hourOfWeek: Int
    public var sampleCount: Int
    public var q10Seconds: Double
    public var q50Seconds: Double
    public var q90Seconds: Double
    public var lastUpdated: Date

    public init(bin: BusResidualQuantileBin) {
        self.key = bin.key
        self.route = bin.route
        self.directionName = bin.directionName
        self.stopId = bin.stopId
        self.horizonBucketRaw = bin.horizonBucket.rawValue
        self.hourOfWeek = bin.hourOfWeek
        self.sampleCount = bin.sampleCount
        self.q10Seconds = bin.q10Seconds
        self.q50Seconds = bin.q50Seconds
        self.q90Seconds = bin.q90Seconds
        self.lastUpdated = bin.lastUpdated
    }

    public var asModel: BusResidualQuantileBin? {
        guard let bucket = BusHorizonBucket(rawValue: horizonBucketRaw) else { return nil }
        return BusResidualQuantileBin(
            route: route,
            directionName: directionName,
            stopId: stopId,
            horizonBucket: bucket,
            hourOfWeek: hourOfWeek,
            sampleCount: sampleCount,
            q10Seconds: q10Seconds,
            q50Seconds: q50Seconds,
            q90Seconds: q90Seconds,
            lastUpdated: lastUpdated
        )
    }
}

@Model
public final class CachedBusStopDetourState {
    @Attribute(.unique) public var stopId: Int
    public var addedByDetourIdsJSON: String
    public var removedByDetourIdsJSON: String
    public var fetchedAt: Date

    public init(state: BusStopDetourState, fetchedAt: Date) {
        self.stopId = state.stopId
        self.addedByDetourIdsJSON = (try? String(
            data: JSONEncoder().encode(state.addedByDetourIds),
            encoding: .utf8
        )) ?? "[]"
        self.removedByDetourIdsJSON = (try? String(
            data: JSONEncoder().encode(state.removedByDetourIds),
            encoding: .utf8
        )) ?? "[]"
        self.fetchedAt = fetchedAt
    }

    public var asModel: BusStopDetourState {
        let added = (try? JSONDecoder().decode(
            [String].self,
            from: Data(addedByDetourIdsJSON.utf8)
        )) ?? []
        let removed = (try? JSONDecoder().decode(
            [String].self,
            from: Data(removedByDetourIdsJSON.utf8)
        )) ?? []
        return BusStopDetourState(
            stopId: stopId,
            addedByDetourIds: added,
            removedByDetourIds: removed
        )
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
        self.detailURLString = alert.detailURL?.absoluteString
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
            isMajor: isMajor,
            detailURL: detailURLString.flatMap(URL.init(string:))
        )
    }
}
