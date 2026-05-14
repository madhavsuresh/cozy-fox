import Foundation

/// Coarse, semantic classification of the device's current motion, sourced
/// from the M-series motion coprocessor via Core Motion. Stored alongside
/// observations so the autopinner can tell "about to leave home" (walking)
/// apart from "still at home" (stationary) without ever needing a GPS trace.
public enum MotionContext: String, Codable, Sendable, Hashable {
    case unknown
    case stationary
    case walking
    case running
    case cycling
    case automotive
}

/// Coarse, on-device history used for commute prediction.
///
/// This intentionally stores semantic states and route choices, not a raw GPS
/// trace. Route pins may include coarse origin/destination buckets so the trip
/// planner can recognize familiar corridors without retaining exact travel
/// points.
public struct MobilityProfile: Codable, Sendable, Hashable {
    public struct RouteLocation: Codable, Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double
        public let label: String?

        public init(latitude: Double, longitude: Double, label: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.label = label
        }

        public static func bucketed(
            latitude: Double,
            longitude: Double,
            label: String? = nil,
            cellDegrees: Double = 0.0025
        ) -> RouteLocation {
            let scale = 1 / cellDegrees
            return RouteLocation(
                latitude: (latitude * scale).rounded() / scale,
                longitude: (longitude * scale).rounded() / scale,
                label: label
            )
        }
    }

    public struct Observation: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let recordedAt: Date
        public let context: CommuteContext
        public let source: Source
        public let direction: CommuteDirection?
        public let weekday: Int
        public let hour: Int
        public let motion: MotionContext?

        public init(
            id: UUID = UUID(),
            recordedAt: Date,
            context: CommuteContext,
            source: Source,
            direction: CommuteDirection?,
            weekday: Int,
            hour: Int,
            motion: MotionContext? = nil
        ) {
            self.id = id
            self.recordedAt = recordedAt
            self.context = context
            self.source = source
            self.direction = direction
            self.weekday = weekday
            self.hour = hour
            self.motion = motion
        }

        public enum Source: String, Codable, Sendable {
            case foreground
            case enteredHome
            case exitedHome
            case enteredWork
            case exitedWork
        }
    }

    public struct RouteObservation: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let recordedAt: Date
        public let direction: CommuteDirection
        public let context: CommuteContext
        public let line: LineColor?
        public let stationId: Int?
        public let busRoute: String?
        public let busDirection: String?
        public let metraRoute: String?
        public let metraStationId: String?
        public let metraDirectionId: Int?
        public let origin: RouteLocation?
        public let destination: RouteLocation?
        public let weekday: Int
        public let hour: Int
        public let motion: MotionContext?

        public init(
            id: UUID = UUID(),
            recordedAt: Date,
            direction: CommuteDirection,
            context: CommuteContext,
            line: LineColor?,
            stationId: Int?,
            busRoute: String?,
            busDirection: String?,
            metraRoute: String? = nil,
            metraStationId: String? = nil,
            metraDirectionId: Int? = nil,
            origin: RouteLocation? = nil,
            destination: RouteLocation? = nil,
            weekday: Int,
            hour: Int,
            motion: MotionContext? = nil
        ) {
            self.id = id
            self.recordedAt = recordedAt
            self.direction = direction
            self.context = context
            self.line = line
            self.stationId = stationId
            self.busRoute = busRoute
            self.busDirection = busDirection
            self.metraRoute = metraRoute
            self.metraStationId = metraStationId
            self.metraDirectionId = metraDirectionId
            self.origin = origin
            self.destination = destination
            self.weekday = weekday
            self.hour = hour
            self.motion = motion
        }
    }

    public var observations: [Observation]
    public var routeObservations: [RouteObservation]
    public var updatedAt: Date?

    public init(
        observations: [Observation] = [],
        routeObservations: [RouteObservation] = [],
        updatedAt: Date? = nil
    ) {
        self.observations = observations
        self.routeObservations = routeObservations
        self.updatedAt = updatedAt
    }

    public static let empty = MobilityProfile()

    public mutating func recordObservation(
        context: CommuteContext,
        source: Observation.Source,
        direction: CommuteDirection? = nil,
        motion: MotionContext? = nil,
        at date: Date = .now,
        calendar: Calendar = .current
    ) {
        if let last = observations.last,
           last.context == context,
           last.source == source,
           last.direction == direction,
           last.motion == motion,
           date.timeIntervalSince(last.recordedAt) < 15 * 60
        {
            return
        }

        observations.append(Observation(
            recordedAt: date,
            context: context,
            source: source,
            direction: direction,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            motion: motion
        ))
        updatedAt = date
        prune(relativeTo: date)
    }

    public mutating func recordRouteObservation(
        direction: CommuteDirection,
        context: CommuteContext,
        line: LineColor?,
        stationId: Int?,
        busRoute: String?,
        busDirection: String?,
        metraRoute: String? = nil,
        metraStationId: String? = nil,
        metraDirectionId: Int? = nil,
        origin: RouteLocation? = nil,
        destination: RouteLocation? = nil,
        motion: MotionContext? = nil,
        at date: Date = .now,
        calendar: Calendar = .current
    ) {
        guard line != nil || busRoute != nil || metraRoute != nil else { return }
        routeObservations.append(RouteObservation(
            recordedAt: date,
            direction: direction,
            context: context,
            line: line,
            stationId: stationId,
            busRoute: busRoute,
            busDirection: busDirection,
            metraRoute: metraRoute,
            metraStationId: metraStationId,
            metraDirectionId: metraDirectionId,
            origin: origin,
            destination: destination,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            motion: motion
        ))
        updatedAt = date
        prune(relativeTo: date)
    }

    public mutating func prune(relativeTo date: Date = .now) {
        let cutoff = date.addingTimeInterval(-90 * 24 * 60 * 60)
        observations = observations
            .filter { $0.recordedAt >= cutoff }
            .suffixArray(limit: 512)
        routeObservations = routeObservations
            .filter { $0.recordedAt >= cutoff }
            .suffixArray(limit: 160)
    }
}

private extension Array {
    func suffixArray(limit: Int) -> [Element] {
        guard count > limit else { return self }
        return Array(suffix(limit))
    }
}
