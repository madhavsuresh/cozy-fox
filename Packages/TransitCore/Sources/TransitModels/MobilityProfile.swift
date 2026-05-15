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

        public func bucketKey(cellDegrees: Double = 0.0025) -> String {
            let scale = 1 / cellDegrees
            let lat = Int((latitude * scale).rounded())
            let lon = Int((longitude * scale).rounded())
            return "\(lat):\(lon)"
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
        public let trainDestination: String?
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
            trainDestination: String? = nil,
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
            self.trainDestination = trainDestination
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

    /// One lightweight, semantic record of a commute leg. This intentionally
    /// stores route identity, anchors, and durations rather than a raw trace.
    public struct CommuteLegObservation: Codable, Sendable, Hashable, Identifiable {
        public enum Mode: String, Codable, Sendable, Hashable {
            case train
            case bus
            case metra
            case divvy
        }

        public enum AnchorKind: String, Codable, Sendable, Hashable {
            case home
            case work
            case custom
            case unknown
        }

        public enum SampleQuality: String, Codable, Sendable, Hashable {
            /// Region-exit paired with an observed CTA L boarding event.
            case observedBoarding
            /// Anchor-exit/entry or route-choice inference without a precise
            /// boarding point.
            case inferred
        }

        public let id: UUID
        public let recordedAt: Date
        public let direction: CommuteDirection
        public let mode: Mode
        public let routeId: String?
        public let stopId: String?
        public let stopLabel: String?
        public let originAnchor: AnchorKind
        public let destinationAnchor: AnchorKind
        public let accessSeconds: TimeInterval
        public let totalSeconds: TimeInterval?
        public let weekday: Int
        public let hour: Int
        public let sampleQuality: SampleQuality

        public init(
            id: UUID = UUID(),
            recordedAt: Date,
            direction: CommuteDirection,
            mode: Mode,
            routeId: String?,
            stopId: String?,
            stopLabel: String? = nil,
            originAnchor: AnchorKind,
            destinationAnchor: AnchorKind,
            accessSeconds: TimeInterval,
            totalSeconds: TimeInterval? = nil,
            weekday: Int,
            hour: Int,
            sampleQuality: SampleQuality
        ) {
            self.id = id
            self.recordedAt = recordedAt
            self.direction = direction
            self.mode = mode
            self.routeId = routeId
            self.stopId = stopId
            self.stopLabel = stopLabel
            self.originAnchor = originAnchor
            self.destinationAnchor = destinationAnchor
            self.accessSeconds = accessSeconds
            self.totalSeconds = totalSeconds
            self.weekday = weekday
            self.hour = hour
            self.sampleQuality = sampleQuality
        }
    }

    /// How long the raw `observations` / `routeObservations` arrays are kept.
    /// Longer-term behavior survives in `summary` after a row ages out.
    public static let rawRetentionDays: Double = 14

    public var observations: [Observation]
    public var routeObservations: [RouteObservation]
    public var commuteLegObservations: [CommuteLegObservation]
    public var updatedAt: Date?
    /// Derived, long-term distillation of past observations. Built and updated
    /// out-of-band by `MobilityProfileSummarizer` so we can keep raw history
    /// short without losing the user's learned patterns.
    public var summary: MobilityProfileSummary

    public init(
        observations: [Observation] = [],
        routeObservations: [RouteObservation] = [],
        commuteLegObservations: [CommuteLegObservation] = [],
        updatedAt: Date? = nil,
        summary: MobilityProfileSummary = .empty
    ) {
        self.observations = observations
        self.routeObservations = routeObservations
        self.commuteLegObservations = commuteLegObservations
        self.updatedAt = updatedAt
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case observations
        case routeObservations
        case commuteLegObservations
        case updatedAt
        case summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.observations = (try? c.decode([Observation].self, forKey: .observations)) ?? []
        self.routeObservations = (try? c.decode([RouteObservation].self, forKey: .routeObservations)) ?? []
        self.commuteLegObservations = (try? c.decode([CommuteLegObservation].self, forKey: .commuteLegObservations)) ?? []
        self.updatedAt = try? c.decode(Date.self, forKey: .updatedAt)
        var summary = (try? c.decode(MobilityProfileSummary.self, forKey: .summary)) ?? .empty
        // First load after upgrading from a pre-summary version: fold the
        // existing 90-day raw history into the summary BEFORE the new
        // 14-day retention prunes it away. The decoder is the earliest hook
        // that runs in every consumer, so this avoids data loss when
        // LocationCoordinator records a foreground observation at launch.
        if summary.isEmpty,
           summary.lastSummarizedAt == nil,
           !self.observations.isEmpty || !self.routeObservations.isEmpty
        {
            for observation in self.observations {
                summary.fold(observation: observation)
            }
            for observation in self.routeObservations {
                summary.fold(routeObservation: observation)
            }
            for observation in self.commuteLegObservations {
                summary.fold(commuteLegObservation: observation)
            }
        }
        self.summary = summary
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

        let observation = Observation(
            recordedAt: date,
            context: context,
            source: source,
            direction: direction,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            motion: motion
        )
        observations.append(observation)
        updatedAt = date
        summary.fold(observation: observation)
        prune(relativeTo: date)
    }

    public mutating func recordRouteObservation(
        direction: CommuteDirection,
        context: CommuteContext,
        line: LineColor?,
        stationId: Int?,
        trainDestination: String? = nil,
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
        let observation = RouteObservation(
            recordedAt: date,
            direction: direction,
            context: context,
            line: line,
            stationId: stationId,
            trainDestination: trainDestination,
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
        )
        routeObservations.append(observation)
        updatedAt = date
        summary.fold(routeObservation: observation)
        prune(relativeTo: date)
    }

    public mutating func recordCommuteLegObservation(
        direction: CommuteDirection,
        mode: CommuteLegObservation.Mode,
        routeId: String?,
        stopId: String?,
        stopLabel: String? = nil,
        originAnchor: CommuteLegObservation.AnchorKind,
        destinationAnchor: CommuteLegObservation.AnchorKind,
        accessSeconds: TimeInterval,
        totalSeconds: TimeInterval? = nil,
        sampleQuality: CommuteLegObservation.SampleQuality,
        at date: Date = .now,
        calendar: Calendar = .current
    ) {
        guard accessSeconds > 0 else { return }
        let observation = CommuteLegObservation(
            recordedAt: date,
            direction: direction,
            mode: mode,
            routeId: routeId,
            stopId: stopId,
            stopLabel: stopLabel,
            originAnchor: originAnchor,
            destinationAnchor: destinationAnchor,
            accessSeconds: accessSeconds,
            totalSeconds: totalSeconds,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            sampleQuality: sampleQuality
        )
        commuteLegObservations.append(observation)
        updatedAt = date
        summary.fold(commuteLegObservation: observation)
        prune(relativeTo: date)
    }

    public mutating func prune(relativeTo date: Date = .now) {
        let cutoff = date.addingTimeInterval(-Self.rawRetentionDays * 24 * 60 * 60)
        observations = observations
            .filter { $0.recordedAt >= cutoff }
            .suffixArray(limit: 512)
        routeObservations = routeObservations
            .filter { $0.recordedAt >= cutoff }
            .suffixArray(limit: 160)
        commuteLegObservations = commuteLegObservations
            .filter { $0.recordedAt >= cutoff }
            .suffixArray(limit: 160)
    }
}

/// Long-lived, derived distillation of `MobilityProfile.observations` and
/// `MobilityProfile.routeObservations`. Holds count-based aggregates so the
/// commute predictor can still see "Monday 8 AM brown line from Logan Square"
/// after the raw row aged out.
///
/// Built and refreshed by `MobilityProfileSummarizer` in `TransitDomain`. The
/// model lives in `TransitModels` so the existing persistence/widget code can
/// decode profiles without taking a new dependency on the domain layer.
public struct MobilityProfileSummary: Codable, Sendable, Hashable {
    /// Departure histogram for one (source × direction) pair, grouped by
    /// weekday and hour. Used to predict departure windows from home and work.
    public struct DepartureWindow: Codable, Sendable, Hashable {
        public var weekdayHourCounts: [String: Int]
        public var totalCount: Int
        public var latestSampleAt: Date?

        public init(
            weekdayHourCounts: [String: Int] = [:],
            totalCount: Int = 0,
            latestSampleAt: Date? = nil
        ) {
            self.weekdayHourCounts = weekdayHourCounts
            self.totalCount = totalCount
            self.latestSampleAt = latestSampleAt
        }

        public static func key(weekday: Int, hour: Int) -> String {
            "\(weekday):\(hour)"
        }

        public static func decompose(key: String) -> (weekday: Int, hour: Int)? {
            let parts = key.split(separator: ":")
            guard parts.count == 2,
                  let weekday = Int(parts[0]),
                  let hour = Int(parts[1])
            else { return nil }
            return (weekday, hour)
        }

        /// Returns the (weekday, hour) bucket with the most samples, or nil if
        /// no samples have been recorded. Ties broken by earliest hour, then
        /// earliest weekday, for stable display ordering.
        public var peakBucket: (weekday: Int, hour: Int)? {
            var best: (key: String, count: Int)?
            for (key, count) in weekdayHourCounts {
                if let current = best {
                    if count > current.count
                        || (count == current.count && key < current.key)
                    {
                        best = (key, count)
                    }
                } else {
                    best = (key, count)
                }
            }
            return best.flatMap { Self.decompose(key: $0.key) }
        }

        /// Returns the most common hour-of-day across all weekdays.
        public var peakHour: Int? {
            var byHour: [Int: Int] = [:]
            for (key, count) in weekdayHourCounts {
                guard let parsed = Self.decompose(key: key) else { continue }
                byHour[parsed.hour, default: 0] += count
            }
            return byHour.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key
        }

        public func count(weekday: Int, hour: Int) -> Int {
            weekdayHourCounts[Self.key(weekday: weekday, hour: hour)] ?? 0
        }

        /// True when there are at least `minSamples` observations within
        /// `±hourWindow` hours of `hour` on the same `weekday`.
        public func matchesWindow(
            weekday: Int,
            hour: Int,
            hourWindow: Int = 1,
            minSamples: Int = 2
        ) -> Bool {
            guard !weekdayHourCounts.isEmpty else { return false }
            var samples = 0
            for offset in -hourWindow...hourWindow {
                let h = ((hour + offset) % 24 + 24) % 24
                samples += count(weekday: weekday, hour: h)
            }
            return samples >= minSamples
        }
    }

    /// Frequency profile for a single resolved (direction, mode-keyed) choice,
    /// keyed across station/stop, origin bucket, destination bucket, weekday,
    /// and hour. Each field stores a histogram so the predictor can pick a
    /// likely station/stop AND a likely time-of-day match.
    public struct RoutePattern: Codable, Sendable, Hashable {
        public var direction: CommuteDirection
        public var mode: Mode
        /// Train line raw value, bus route string, or Metra route id.
        public var routeId: String
        public var totalCount: Int
        public var weekdayCounts: [String: Int]
        public var hourCounts: [String: Int]
        public var stationCounts: [String: Int]
        public var directionLabelCounts: [String: Int]
        public var originBucketCounts: [String: Int]
        public var destinationBucketCounts: [String: Int]
        public var latestSampleAt: Date

        public enum Mode: String, Codable, Sendable, Hashable {
            case train
            case bus
            case metra
        }

        public init(
            direction: CommuteDirection,
            mode: Mode,
            routeId: String,
            totalCount: Int = 0,
            weekdayCounts: [String: Int] = [:],
            hourCounts: [String: Int] = [:],
            stationCounts: [String: Int] = [:],
            directionLabelCounts: [String: Int] = [:],
            originBucketCounts: [String: Int] = [:],
            destinationBucketCounts: [String: Int] = [:],
            latestSampleAt: Date
        ) {
            self.direction = direction
            self.mode = mode
            self.routeId = routeId
            self.totalCount = totalCount
            self.weekdayCounts = weekdayCounts
            self.hourCounts = hourCounts
            self.stationCounts = stationCounts
            self.directionLabelCounts = directionLabelCounts
            self.originBucketCounts = originBucketCounts
            self.destinationBucketCounts = destinationBucketCounts
            self.latestSampleAt = latestSampleAt
        }

        public static func key(direction: CommuteDirection, mode: Mode, routeId: String) -> String {
            "\(direction.rawValue):\(mode.rawValue):\(routeId)"
        }

        public var key: String {
            Self.key(direction: direction, mode: mode, routeId: routeId)
        }

        public var topStationId: String? {
            stationCounts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key
        }

        public var topDirectionLabel: String? {
            directionLabelCounts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key
        }
    }

    /// Long-lived aggregate for learned access/commute timing by route and
    /// anchor pair.
    public struct CommuteLegPattern: Codable, Sendable, Hashable {
        public var direction: CommuteDirection
        public var mode: MobilityProfile.CommuteLegObservation.Mode
        public var routeId: String?
        public var stopId: String?
        public var originAnchor: MobilityProfile.CommuteLegObservation.AnchorKind
        public var destinationAnchor: MobilityProfile.CommuteLegObservation.AnchorKind
        public var totalCount: Int
        public var accessMeanSeconds: Double
        public var accessM2Seconds: Double
        public var totalMeanSeconds: Double
        public var totalM2Seconds: Double
        public var totalDurationCount: Int
        public var weekdayCounts: [String: Int]
        public var hourCounts: [String: Int]
        public var latestSampleAt: Date

        public init(
            direction: CommuteDirection,
            mode: MobilityProfile.CommuteLegObservation.Mode,
            routeId: String?,
            stopId: String?,
            originAnchor: MobilityProfile.CommuteLegObservation.AnchorKind,
            destinationAnchor: MobilityProfile.CommuteLegObservation.AnchorKind,
            totalCount: Int = 0,
            accessMeanSeconds: Double = 0,
            accessM2Seconds: Double = 0,
            totalMeanSeconds: Double = 0,
            totalM2Seconds: Double = 0,
            totalDurationCount: Int = 0,
            weekdayCounts: [String: Int] = [:],
            hourCounts: [String: Int] = [:],
            latestSampleAt: Date
        ) {
            self.direction = direction
            self.mode = mode
            self.routeId = routeId
            self.stopId = stopId
            self.originAnchor = originAnchor
            self.destinationAnchor = destinationAnchor
            self.totalCount = totalCount
            self.accessMeanSeconds = accessMeanSeconds
            self.accessM2Seconds = accessM2Seconds
            self.totalMeanSeconds = totalMeanSeconds
            self.totalM2Seconds = totalM2Seconds
            self.totalDurationCount = totalDurationCount
            self.weekdayCounts = weekdayCounts
            self.hourCounts = hourCounts
            self.latestSampleAt = latestSampleAt
        }

        public static func key(
            direction: CommuteDirection,
            mode: MobilityProfile.CommuteLegObservation.Mode,
            routeId: String?,
            stopId: String?,
            originAnchor: MobilityProfile.CommuteLegObservation.AnchorKind,
            destinationAnchor: MobilityProfile.CommuteLegObservation.AnchorKind
        ) -> String {
            [
                direction.rawValue,
                mode.rawValue,
                routeId ?? "_",
                stopId ?? "_",
                originAnchor.rawValue,
                destinationAnchor.rawValue,
            ].joined(separator: ":")
        }

        public var key: String {
            Self.key(
                direction: direction,
                mode: mode,
                routeId: routeId,
                stopId: stopId,
                originAnchor: originAnchor,
                destinationAnchor: destinationAnchor
            )
        }

        public var accessStandardDeviationSeconds: Double? {
            guard totalCount >= 2 else { return nil }
            return (accessM2Seconds / Double(totalCount - 1)).squareRoot()
        }

        public var totalStandardDeviationSeconds: Double? {
            guard totalDurationCount >= 2 else { return nil }
            return (totalM2Seconds / Double(totalDurationCount - 1)).squareRoot()
        }

        public mutating func record(_ observation: MobilityProfile.CommuteLegObservation) {
            totalCount += 1
            let accessDelta = observation.accessSeconds - accessMeanSeconds
            accessMeanSeconds += accessDelta / Double(totalCount)
            let accessDelta2 = observation.accessSeconds - accessMeanSeconds
            accessM2Seconds += accessDelta * accessDelta2

            if let total = observation.totalSeconds, total > 0 {
                totalDurationCount += 1
                let totalDelta = total - totalMeanSeconds
                totalMeanSeconds += totalDelta / Double(totalDurationCount)
                let totalDelta2 = total - totalMeanSeconds
                totalM2Seconds += totalDelta * totalDelta2
            }

            weekdayCounts[String(observation.weekday), default: 0] += 1
            hourCounts[String(observation.hour), default: 0] += 1
            latestSampleAt = max(latestSampleAt, observation.recordedAt)
        }
    }

    /// Departure windows keyed by `Observation.Source.rawValue + ":" + direction.rawValue`.
    public var departureWindows: [String: DepartureWindow]
    /// Route patterns keyed by `RoutePattern.key`.
    public var routePatterns: [String: RoutePattern]
    /// Commute-leg timing patterns keyed by `CommuteLegPattern.key`.
    public var commuteLegPatterns: [String: CommuteLegPattern]
    /// When the summary was last folded forward. Observations strictly after
    /// this date are the ones the summarizer still needs to consume.
    public var lastSummarizedAt: Date?
    /// Total observations the summary has consumed so far. Used for UI display.
    public var consumedObservationCount: Int
    /// Total route observations the summary has consumed so far. Used for UI
    /// display and to gauge how much learning has accumulated.
    public var consumedRouteObservationCount: Int
    /// Total commute-leg timing observations folded into the summary.
    public var consumedCommuteLegObservationCount: Int

    public init(
        departureWindows: [String: DepartureWindow] = [:],
        routePatterns: [String: RoutePattern] = [:],
        commuteLegPatterns: [String: CommuteLegPattern] = [:],
        lastSummarizedAt: Date? = nil,
        consumedObservationCount: Int = 0,
        consumedRouteObservationCount: Int = 0,
        consumedCommuteLegObservationCount: Int = 0
    ) {
        self.departureWindows = departureWindows
        self.routePatterns = routePatterns
        self.commuteLegPatterns = commuteLegPatterns
        self.lastSummarizedAt = lastSummarizedAt
        self.consumedObservationCount = consumedObservationCount
        self.consumedRouteObservationCount = consumedRouteObservationCount
        self.consumedCommuteLegObservationCount = consumedCommuteLegObservationCount
    }

    private enum CodingKeys: String, CodingKey {
        case departureWindows
        case routePatterns
        case commuteLegPatterns
        case lastSummarizedAt
        case consumedObservationCount
        case consumedRouteObservationCount
        case consumedCommuteLegObservationCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.departureWindows = (try? c.decode([String: DepartureWindow].self, forKey: .departureWindows)) ?? [:]
        self.routePatterns = (try? c.decode([String: RoutePattern].self, forKey: .routePatterns)) ?? [:]
        self.commuteLegPatterns = (try? c.decode([String: CommuteLegPattern].self, forKey: .commuteLegPatterns)) ?? [:]
        self.lastSummarizedAt = try? c.decode(Date.self, forKey: .lastSummarizedAt)
        self.consumedObservationCount = (try? c.decode(Int.self, forKey: .consumedObservationCount)) ?? 0
        self.consumedRouteObservationCount = (try? c.decode(Int.self, forKey: .consumedRouteObservationCount)) ?? 0
        self.consumedCommuteLegObservationCount = (try? c.decode(Int.self, forKey: .consumedCommuteLegObservationCount)) ?? 0
    }

    public static let empty = MobilityProfileSummary()

    public static func departureKey(
        source: MobilityProfile.Observation.Source,
        direction: CommuteDirection
    ) -> String {
        "\(source.rawValue):\(direction.rawValue)"
    }

    public func departureWindow(
        source: MobilityProfile.Observation.Source,
        direction: CommuteDirection
    ) -> DepartureWindow? {
        departureWindows[Self.departureKey(source: source, direction: direction)]
    }

    public func patterns(direction: CommuteDirection) -> [RoutePattern] {
        routePatterns.values.filter { $0.direction == direction }
    }

    public func commuteLegs(
        direction: CommuteDirection? = nil,
        mode: MobilityProfile.CommuteLegObservation.Mode? = nil,
        routeId: String? = nil,
        stopId: String? = nil
    ) -> [CommuteLegPattern] {
        commuteLegPatterns.values.filter { pattern in
            if let direction, pattern.direction != direction { return false }
            if let mode, pattern.mode != mode { return false }
            if let routeId, pattern.routeId != routeId { return false }
            if let stopId, pattern.stopId != stopId { return false }
            return true
        }
    }

    public var isEmpty: Bool {
        departureWindows.isEmpty && routePatterns.isEmpty && commuteLegPatterns.isEmpty
    }

    /// Folds a single observation into the summary in place. Advances
    /// `lastSummarizedAt` to the observation's date so the explicit summarizer
    /// won't double-count it on a subsequent refresh.
    public mutating func fold(observation: MobilityProfile.Observation) {
        guard let direction = observation.direction else {
            advanceCursor(to: observation.recordedAt)
            return
        }
        let onlyExitSources: Set<MobilityProfile.Observation.Source> = [.exitedHome, .exitedWork]
        guard onlyExitSources.contains(observation.source) else {
            advanceCursor(to: observation.recordedAt)
            return
        }

        let key = Self.departureKey(source: observation.source, direction: direction)
        var window = departureWindows[key] ?? DepartureWindow()
        let bucket = DepartureWindow.key(
            weekday: observation.weekday,
            hour: observation.hour
        )
        window.weekdayHourCounts[bucket, default: 0] += 1
        window.totalCount += 1
        if let latest = window.latestSampleAt {
            window.latestSampleAt = max(latest, observation.recordedAt)
        } else {
            window.latestSampleAt = observation.recordedAt
        }
        departureWindows[key] = window
        consumedObservationCount += 1
        advanceCursor(to: observation.recordedAt)
    }

    /// Folds a single route observation into the summary in place.
    public mutating func fold(routeObservation observation: MobilityProfile.RouteObservation) {
        let originBucket = observation.origin?.bucketKey()
        let destinationBucket = observation.destination?.bucketKey()
        let weekdayKey = String(observation.weekday)
        let hourKey = String(observation.hour)

        var counted = false
        if let line = observation.line {
            upsertPattern(
                direction: observation.direction,
                mode: .train,
                routeId: line.rawValue,
                stationId: observation.stationId.map(String.init),
                directionLabel: observation.trainDestination,
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }
        if let route = observation.busRoute {
            upsertPattern(
                direction: observation.direction,
                mode: .bus,
                routeId: route,
                stationId: nil,
                directionLabel: observation.busDirection,
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }
        if let route = observation.metraRoute {
            upsertPattern(
                direction: observation.direction,
                mode: .metra,
                routeId: route,
                stationId: observation.metraStationId,
                directionLabel: observation.metraDirectionId.map(String.init),
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }
        if counted {
            consumedRouteObservationCount += 1
        }
        advanceCursor(to: observation.recordedAt)
    }

    public mutating func fold(commuteLegObservation observation: MobilityProfile.CommuteLegObservation) {
        let key = CommuteLegPattern.key(
            direction: observation.direction,
            mode: observation.mode,
            routeId: observation.routeId,
            stopId: observation.stopId,
            originAnchor: observation.originAnchor,
            destinationAnchor: observation.destinationAnchor
        )
        var pattern = commuteLegPatterns[key] ?? CommuteLegPattern(
            direction: observation.direction,
            mode: observation.mode,
            routeId: observation.routeId,
            stopId: observation.stopId,
            originAnchor: observation.originAnchor,
            destinationAnchor: observation.destinationAnchor,
            latestSampleAt: observation.recordedAt
        )
        pattern.record(observation)
        commuteLegPatterns[key] = pattern
        consumedCommuteLegObservationCount += 1
        advanceCursor(to: observation.recordedAt)
    }

    private mutating func advanceCursor(to date: Date) {
        if let cursor = lastSummarizedAt {
            lastSummarizedAt = max(cursor, date)
        } else {
            lastSummarizedAt = date
        }
    }

    private mutating func upsertPattern(
        direction: CommuteDirection,
        mode: RoutePattern.Mode,
        routeId: String,
        stationId: String?,
        directionLabel: String?,
        originBucket: String?,
        destinationBucket: String?,
        weekdayKey: String,
        hourKey: String,
        recordedAt: Date
    ) {
        let key = RoutePattern.key(direction: direction, mode: mode, routeId: routeId)
        var pattern = routePatterns[key] ?? RoutePattern(
            direction: direction,
            mode: mode,
            routeId: routeId,
            latestSampleAt: recordedAt
        )
        pattern.totalCount += 1
        pattern.weekdayCounts[weekdayKey, default: 0] += 1
        pattern.hourCounts[hourKey, default: 0] += 1
        if let stationId, !stationId.isEmpty {
            pattern.stationCounts[stationId, default: 0] += 1
        }
        if let directionLabel, !directionLabel.isEmpty {
            pattern.directionLabelCounts[directionLabel, default: 0] += 1
        }
        if let originBucket {
            pattern.originBucketCounts[originBucket, default: 0] += 1
        }
        if let destinationBucket {
            pattern.destinationBucketCounts[destinationBucket, default: 0] += 1
        }
        pattern.latestSampleAt = max(pattern.latestSampleAt, recordedAt)
        routePatterns[key] = pattern
    }
}

private extension Array {
    func suffixArray(limit: Int) -> [Element] {
        guard count > limit else { return self }
        return Array(suffix(limit))
    }
}
