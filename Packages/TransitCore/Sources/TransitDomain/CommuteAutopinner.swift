import Foundation
import TransitModels

/// Local, privacy-preserving commute pinning.
///
/// The predictor works with semantic home/work/neither state plus coarse time
/// buckets. It never needs to upload locations or retain a raw trajectory.
public struct CommuteAutopinner: Sendable {
    public struct Result: Sendable, Hashable {
        public let preferences: UserRoutePreferences
        public let changed: Bool
        public let direction: CommuteDirection?
        public let reason: Reason

        public enum Reason: String, Sendable, Hashable {
            case disabled
            case manualOverride
            case missingLocation
            case missingAnchor
            case notInCommuteWindow
            case suppressedByMotion
            case heldDuringTransit
            case noRoute
            case unchanged
            case pinned
            case cleared
        }
    }

    private struct RouteChoice: Sendable, Hashable {
        var line: LineColor? = nil
        var stationId: Int? = nil
        var busRoute: String? = nil
        var busDirection: String? = nil
        var busStopId: Int? = nil
        var metraRoute: String? = nil
        var metraStationId: String? = nil
        var metraDirectionId: Int? = nil

        var isEmpty: Bool {
            line == nil && busRoute == nil && metraRoute == nil
        }

        mutating func fillMissing(from other: RouteChoice) {
            if line == nil {
                line = other.line
                stationId = other.stationId
            }
            if busRoute == nil {
                busRoute = other.busRoute
                busDirection = other.busDirection
                busStopId = other.busStopId
            }
            if metraRoute == nil {
                metraRoute = other.metraRoute
                metraStationId = other.metraStationId
                metraDirectionId = other.metraDirectionId
            }
        }
    }

    private struct PinFields: Equatable {
        let line: LineColor?
        let stationId: Int?
        let trainDestination: String?
        let busRoute: String?
        let busDirection: String?
        let busStopId: Int?
        let metraRoute: String?
        let metraStationId: String?
        let metraDirectionId: Int?
        let autoPinnedDirection: CommuteDirection?
    }

    public let clock: Clock
    public let planner: LocalTransitPlanner
    public let manualOverrideSeconds: TimeInterval

    public init(
        clock: Clock = SystemClock(),
        planner: LocalTransitPlanner = LocalTransitPlanner(),
        manualOverrideSeconds: TimeInterval = 30 * 60
    ) {
        self.clock = clock
        self.planner = planner
        self.manualOverrideSeconds = manualOverrideSeconds
    }

    public func apply(
        preferences: UserRoutePreferences,
        anchors: CommuteAnchors,
        profile: MobilityProfile,
        location: LastKnownLocation?,
        context: CommuteContext,
        motion: MotionContext? = nil
    ) -> Result {
        guard preferences.autopinEnabled else {
            return .init(preferences: preferences, changed: false, direction: nil, reason: .disabled)
        }
        guard !hasActiveManualOverride(preferences) else {
            return .init(preferences: preferences, changed: false, direction: nil, reason: .manualOverride)
        }
        // While the user is actively in a vehicle or on a bike with an
        // automatic pin already showing, hold steady — region-edge crossings
        // shouldn't flicker the pin mid-trip.
        if let motion, motion == .automotive || motion == .cycling,
           preferences.pinSource == .automatic, preferences.hasPinnedTransit {
            return .init(
                preferences: preferences,
                changed: false,
                direction: preferences.autoPinnedDirection,
                reason: .heldDuringTransit
            )
        }
        guard let location else {
            return .init(preferences: preferences, changed: false, direction: nil, reason: .missingLocation)
        }
        guard let direction = predictedDirection(context: context, profile: profile, motion: motion) else {
            let reason: Result.Reason = (context == .atHome && motion == .stationary)
                ? .suppressedByMotion
                : .notInCommuteWindow
            return clearAutomaticPins(preferences, reason: reason)
        }
        guard let target = targetAnchor(for: direction, anchors: anchors) else {
            return clearAutomaticPins(preferences, reason: .missingAnchor)
        }

        let origin = PlannerCoordinate(latitude: location.latitude, longitude: location.longitude)
        let destination = PlannerCoordinate(latitude: target.latitude, longitude: target.longitude)
        var choice = routePreferenceChoice(preferences, direction: direction)
        choice.fillMissing(from: learnedRouteChoice(
            profile: profile,
            preferences: preferences,
            direction: direction,
            origin: origin
        ))
        choice.fillMissing(from: localRouteChoice(
            from: origin,
            to: destination,
            preferences: preferences
        ))

        guard !choice.isEmpty else {
            return clearAutomaticPins(preferences, reason: .noRoute)
        }

        var updated = preferences
        updated.pinnedLine = choice.line
        updated.pinnedStationId = choice.stationId
        updated.pinnedTrainDestination = nil
        updated.pinnedBusRoute = choice.busRoute
        updated.pinnedBusDirection = choice.busDirection
        updated.pinnedBusStopId = choice.busStopId
        updated.pinnedMetraRoute = choice.metraRoute
        updated.pinnedMetraStationId = choice.metraStationId
        updated.pinnedMetraDirectionId = choice.metraDirectionId
        updated.pinnedMetraDestination = nil
        updated.markAutomaticPin(direction: direction, at: clock.now)

        let changed = pinFields(from: preferences) != pinFields(from: updated)
            || preferences.pinSource != .automatic
            || preferences.autoPinnedDirection != direction
        return .init(
            preferences: changed ? updated : preferences,
            changed: changed,
            direction: direction,
            reason: changed ? .pinned : .unchanged
        )
    }

    private func predictedDirection(
        context: CommuteContext,
        profile: MobilityProfile,
        motion: MotionContext?
    ) -> CommuteDirection? {
        switch context {
        case .atHome:
            // Stationary at home → not commuting; let the caller turn this
            // into a `.suppressedByMotion` reason for the belief panel.
            if motion == .stationary { return nil }
            return shouldSurfaceToWorkFromHome(profile: profile, motion: motion) ? .toWork : nil
        case .atWork, .elsewhere:
            return .toHome
        case .unknown:
            return nil
        }
    }

    private func shouldSurfaceToWorkFromHome(
        profile: MobilityProfile,
        motion: MotionContext?
    ) -> Bool {
        guard isWeekday(clock.now) else { return false }
        // Walking or running on a weekday at home is strong evidence the user
        // is leaving — surface toWork even if we have no learned history or
        // we're outside the usual hour window.
        if motion == .walking || motion == .running { return true }
        let hour = clock.calendar.component(.hour, from: clock.now)
        let weekday = clock.calendar.component(.weekday, from: clock.now)
        let departures = profile.observations.filter {
            $0.source == .exitedHome
                && $0.direction == .toWork
                && isWeekday(weekday: $0.weekday)
        }

        if departures.count >= 3 {
            let sameWeekday = departures.filter { $0.weekday == weekday }
            let sample = sameWeekday.count >= 2 ? sameWeekday : departures
            let byHour = Dictionary(grouping: sample, by: \.hour)
            guard let peak = byHour.max(by: { $0.value.count < $1.value.count })?.key else {
                return false
            }
            return hourDistance(hour, peak) <= 2
        }

        // Raw history has aged out — fall back to the derived summary so we
        // don't lose the user's learned commute window after 14 days.
        if let window = profile.summary.departureWindow(source: .exitedHome, direction: .toWork),
           window.totalCount >= 3
        {
            if window.matchesWindow(weekday: weekday, hour: hour, hourWindow: 2, minSamples: 2) {
                return true
            }
            if let peakHour = window.peakHour {
                return hourDistance(hour, peakHour) <= 2
            }
        }

        return (5...11).contains(hour)
    }

    private func targetAnchor(
        for direction: CommuteDirection,
        anchors: CommuteAnchors
    ) -> CommuteAnchors.Anchor? {
        switch direction {
        case .toHome: return anchors.home
        case .toWork: return anchors.work
        case .anytime: return nil
        }
    }

    private func hasActiveManualOverride(_ preferences: UserRoutePreferences) -> Bool {
        guard let last = preferences.lastManualPinAt else { return false }
        guard clock.now.timeIntervalSince(last) < manualOverrideSeconds else { return false }
        return clock.calendar.isDate(last, inSameDayAs: clock.now)
    }

    private func clearAutomaticPins(
        _ preferences: UserRoutePreferences,
        reason: Result.Reason
    ) -> Result {
        guard preferences.pinSource == .automatic, preferences.hasPinnedTransit else {
            return .init(preferences: preferences, changed: false, direction: nil, reason: reason)
        }
        var updated = preferences
        updated.pinnedLine = nil
        updated.pinnedStationId = nil
        updated.pinnedTrainDestination = nil
        updated.pinnedBusRoute = nil
        updated.pinnedBusDirection = nil
        updated.pinnedBusStopId = nil
        updated.pinnedMetraRoute = nil
        updated.pinnedMetraStationId = nil
        updated.pinnedMetraDirectionId = nil
        updated.pinnedMetraDestination = nil
        updated.autoPinnedDirection = nil
        return .init(preferences: updated, changed: true, direction: nil, reason: .cleared)
    }

    private func routePreferenceChoice(
        _ preferences: UserRoutePreferences,
        direction: CommuteDirection
    ) -> RouteChoice {
        let train = select(
            preferences.trains.filter { preferences.isTrainLineVisible($0.line) },
            direction: direction
        )
        let bus = select(
            preferences.buses.filter { preferences.isBusRouteVisible($0.route) },
            direction: direction
        )
        let metra = select(
            preferences.metra.filter { preferences.isMetraRouteVisible($0.routeId) },
            direction: direction
        )
        return RouteChoice(
            line: train?.line,
            stationId: train?.mapId,
            busRoute: bus?.route,
            busDirection: bus?.directionLabel,
            busStopId: bus?.stopId,
            metraRoute: metra?.routeId,
            metraStationId: metra?.stationId,
            metraDirectionId: metra?.directionId
        )
    }

    private func learnedRouteChoice(
        profile: MobilityProfile,
        preferences: UserRoutePreferences,
        direction: CommuteDirection,
        origin: PlannerCoordinate
    ) -> RouteChoice {
        var lineScores: [LineColor: (score: Double, latest: Date, stationId: Int?)] = [:]
        var busScores: [String: (score: Double, latest: Date, direction: String?)] = [:]
        var metraScores: [String: (score: Double, latest: Date, stationId: String?, directionId: Int?)] = [:]

        for observation in profile.routeObservations where observation.direction == direction {
            let score = score(observation)
            if let line = observation.line, preferences.isTrainLineVisible(line) {
                let current = lineScores[line]
                if current == nil
                    || score > current!.score
                    || (score == current!.score && observation.recordedAt > current!.latest)
                {
                    lineScores[line] = (score, observation.recordedAt, observation.stationId)
                }
            }
            if let route = observation.busRoute, preferences.isBusRouteVisible(route) {
                let current = busScores[route]
                if current == nil
                    || score > current!.score
                    || (score == current!.score && observation.recordedAt > current!.latest)
                {
                    busScores[route] = (score, observation.recordedAt, observation.busDirection)
                }
            }
            if let route = observation.metraRoute, preferences.isMetraRouteVisible(route) {
                let current = metraScores[route]
                if current == nil
                    || score > current!.score
                    || (score == current!.score && observation.recordedAt > current!.latest)
                {
                    metraScores[route] = (
                        score,
                        observation.recordedAt,
                        observation.metraStationId,
                        observation.metraDirectionId
                    )
                }
            }
        }

        // Summary fallback for patterns that have aged out of the raw window.
        // Only fill in modes the raw scan didn't see; the freshly-observed
        // signal still wins when available.
        for pattern in profile.summary.patterns(direction: direction) {
            let score = score(pattern: pattern)
            switch pattern.mode {
            case .train:
                guard let line = LineColor(rawValue: pattern.routeId),
                      preferences.isTrainLineVisible(line),
                      lineScores[line] == nil
                else { continue }
                let stationId = pattern.topStationId.flatMap(Int.init)
                lineScores[line] = (score, pattern.latestSampleAt, stationId)
            case .bus:
                let route = pattern.routeId
                guard preferences.isBusRouteVisible(route), busScores[route] == nil else { continue }
                busScores[route] = (score, pattern.latestSampleAt, pattern.topDirectionLabel)
            case .metra:
                let route = pattern.routeId
                guard preferences.isMetraRouteVisible(route), metraScores[route] == nil else { continue }
                let directionId = pattern.topDirectionLabel.flatMap(Int.init)
                metraScores[route] = (
                    score,
                    pattern.latestSampleAt,
                    pattern.topStationId,
                    directionId
                )
            }
        }

        let bestLine = lineScores.max { $0.value.score < $1.value.score }
        let bestBus = busScores.max { $0.value.score < $1.value.score }
        let bestMetra = metraScores.max { $0.value.score < $1.value.score }

        let validatedLine: (line: LineColor, stationId: Int?)? = bestLine.flatMap { line, value in
            validate(line: line, stationId: value.stationId, origin: origin)
        }
        let validatedBus: (route: String, direction: String?)? = bestBus.flatMap { route, value in
            validate(busRoute: route, direction: value.direction, origin: origin)
        }
        let validatedMetra: (route: String, stationId: String?, directionId: Int?)? = bestMetra.flatMap { route, value in
            validate(
                metraRoute: route,
                stationId: value.stationId,
                directionId: value.directionId,
                origin: origin
            )
        }

        return RouteChoice(
            line: validatedLine?.line,
            stationId: validatedLine?.stationId,
            busRoute: validatedBus?.route,
            busDirection: validatedBus?.direction,
            busStopId: nil,
            metraRoute: validatedMetra?.route,
            metraStationId: validatedMetra?.stationId,
            metraDirectionId: validatedMetra?.directionId
        )
    }

    private func score(pattern: MobilityProfileSummary.RoutePattern) -> Double {
        let weekday = clock.calendar.component(.weekday, from: clock.now)
        let hour = clock.calendar.component(.hour, from: clock.now)
        let totalDouble = Double(pattern.totalCount)
        guard totalDouble > 0 else { return 0 }
        let weekdayFraction = Double(pattern.weekdayCounts[String(weekday)] ?? 0) / totalDouble
        let hourCount = (-2...2).reduce(0) { acc, offset in
            let h = ((hour + offset) % 24 + 24) % 24
            return acc + (pattern.hourCounts[String(h)] ?? 0)
        }
        let hourFraction = Double(hourCount) / totalDouble
        let ageDays = max(0, clock.now.timeIntervalSince(pattern.latestSampleAt) / 86_400)
        let recency = max(0, 1.5 - ageDays / 60)
        return log(totalDouble + 1) * (0.3 + weekdayFraction * 1.5 + hourFraction * 1.5) + recency
    }

    private func localRouteChoice(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate,
        preferences: UserRoutePreferences
    ) -> RouteChoice {
        let plans = planner.plan(from: origin, to: destination)
        var choice = RouteChoice()
        for plan in plans {
            guard let resolution = plan.legs.first(where: { $0.mode == .transit })?.transit?.resolution else {
                continue
            }
            switch resolution {
            case .line(let line) where choice.line == nil && preferences.isTrainLineVisible(line):
                choice.line = line
            case .bus(let route) where choice.busRoute == nil && preferences.isBusRouteVisible(route):
                choice.busRoute = route
                choice.busDirection = inferredBusDirection(route: route, from: origin, to: destination)
            case .metra(let route) where choice.metraRoute == nil && preferences.isMetraRouteVisible(route):
                choice.metraRoute = route
            default:
                continue
            }
        }
        return choice
    }

    private func validate(
        line: LineColor,
        stationId: Int?,
        origin: PlannerCoordinate
    ) -> (line: LineColor, stationId: Int?)? {
        let resolver = NearestStationResolver(maxDistanceMeters: 10_000)
        let originPair = (lat: origin.latitude, lon: origin.longitude)
        if let stationId,
           LStationCatalog.all.contains(where: { $0.id == stationId && $0.servedLines.contains(line) })
        {
            return (line, stationId)
        }
        guard resolver.nearest(onLine: line, to: originPair, catalog: LStationCatalog.all) != nil else {
            return nil
        }
        return (line, nil)
    }

    private func validate(
        busRoute: String,
        direction: String?,
        origin: PlannerCoordinate
    ) -> (route: String, direction: String?)? {
        let resolver = NearestBusStopResolver(maxDistanceMeters: 5_000)
        let originPair = (lat: origin.latitude, lon: origin.longitude)
        let stops = resolver.nearestPerDirection(
            onRoute: busRoute,
            to: originPair,
            catalog: BusStopCatalog.all
        )
        guard !stops.isEmpty else { return nil }
        if let direction, stops.contains(where: { $0.directionLabel == direction }) {
            return (busRoute, direction)
        }
        return (busRoute, nil)
    }

    private func validate(
        metraRoute: String,
        stationId: String?,
        directionId: Int?,
        origin: PlannerCoordinate
    ) -> (route: String, stationId: String?, directionId: Int?)? {
        let resolver = NearestMetraStationResolver(maxDistanceMeters: 20_000)
        let originPair = (lat: origin.latitude, lon: origin.longitude)
        if let stationId,
           MetraStationCatalog.all.contains(where: {
               $0.id == stationId && $0.servedRoutes.contains(metraRoute)
           })
        {
            return (metraRoute, stationId, directionId)
        }
        let nearest = resolver.closestStations(
            onRoute: metraRoute,
            to: originPair,
            limit: 1,
            catalog: MetraStationCatalog.all
        )
        guard let station = nearest.first?.station else { return nil }
        return (metraRoute, station.id, directionId)
    }

    private func inferredBusDirection(
        route: String,
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate
    ) -> String? {
        let resolver = NearestBusStopResolver(maxDistanceMeters: 5_000)
        let stops = resolver.nearestPerDirection(
            onRoute: route,
            to: (origin.latitude, origin.longitude),
            catalog: BusStopCatalog.all
        )
        guard stops.count > 1 else { return stops.first?.directionLabel }

        let targetDirection = directionVector(from: origin, to: destination)
        return stops.min { lhs, rhs in
            directionPenalty(label: lhs.directionLabel, target: targetDirection)
                < directionPenalty(label: rhs.directionLabel, target: targetDirection)
        }?.directionLabel
    }

    private func score(_ observation: MobilityProfile.RouteObservation) -> Double {
        let weekday = clock.calendar.component(.weekday, from: clock.now)
        let hour = clock.calendar.component(.hour, from: clock.now)
        let ageDays = max(0, clock.now.timeIntervalSince(observation.recordedAt) / 86_400)
        let recency = max(0, 3 - ageDays / 14)
        let weekdayBoost = observation.weekday == weekday ? 2.0 : 0
        let hourBoost = max(0, 3 - Double(hourDistance(hour, observation.hour)))
        return 1 + recency + weekdayBoost + hourBoost
    }

    private func select<T>(_ items: [T], direction: CommuteDirection) -> T?
    where T: PreferenceCommute {
        if let match = items.first(where: { $0.direction == direction }) { return match }
        if let any = items.first(where: { $0.direction == .anytime }) { return any }
        return nil
    }

    private func pinFields(
        from preferences: UserRoutePreferences
    ) -> PinFields {
        PinFields(
            line: preferences.pinnedLine,
            stationId: preferences.pinnedStationId,
            trainDestination: preferences.pinnedTrainDestination,
            busRoute: preferences.pinnedBusRoute,
            busDirection: preferences.pinnedBusDirection,
            busStopId: preferences.pinnedBusStopId,
            metraRoute: preferences.pinnedMetraRoute,
            metraStationId: preferences.pinnedMetraStationId,
            metraDirectionId: preferences.pinnedMetraDirectionId,
            autoPinnedDirection: preferences.autoPinnedDirection
        )
    }

    private func isWeekday(_ date: Date) -> Bool {
        isWeekday(weekday: clock.calendar.component(.weekday, from: date))
    }

    private func isWeekday(weekday: Int) -> Bool {
        (2...6).contains(weekday)
    }

    private func hourDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let raw = abs(lhs - rhs)
        return min(raw, 24 - raw)
    }

    private func directionVector(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate
    ) -> (north: Double, east: Double) {
        (
            north: destination.latitude - origin.latitude,
            east: destination.longitude - origin.longitude
        )
    }

    private func directionPenalty(
        label: String,
        target: (north: Double, east: Double)
    ) -> Double {
        let lower = label.lowercased()
        let vector: (north: Double, east: Double)
        if lower.contains("north") || lower == "nb" || lower.contains("nwb") || lower.contains("neb") {
            vector = (1, lower.contains("west") || lower.contains("nwb") ? -0.5 : lower.contains("east") || lower.contains("neb") ? 0.5 : 0)
        } else if lower.contains("south") || lower == "sb" || lower.contains("swb") || lower.contains("seb") {
            vector = (-1, lower.contains("west") || lower.contains("swb") ? -0.5 : lower.contains("east") || lower.contains("seb") ? 0.5 : 0)
        } else if lower.contains("east") || lower == "eb" {
            vector = (0, 1)
        } else if lower.contains("west") || lower == "wb" {
            vector = (0, -1)
        } else {
            return 10
        }
        let dot = vector.north * target.north + vector.east * target.east
        let vm = sqrt(vector.north * vector.north + vector.east * vector.east)
        let tm = sqrt(target.north * target.north + target.east * target.east)
        guard vm > 0, tm > 0 else { return 10 }
        return -(dot / (vm * tm))
    }
}
