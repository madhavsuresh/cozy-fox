import Foundation
import TransitModels

public struct CatchableWindowEvaluator: Sendable {
    public let scorer: TransitOpportunityScorer

    public init(scorer: TransitOpportunityScorer = TransitOpportunityScorer()) {
        self.scorer = scorer
    }

    public func surfacePreferences(
        preferences: UserRoutePreferences,
        profile: MobilityProfile,
        context: CommuteContext,
        trainArrivals: [Arrival],
        busPredictions: [BusPrediction],
        metraPredictions: [MetraPrediction],
        vehiclePositions: [VehiclePosition],
        activeAlerts: [ServiceAlert],
        trainsFetchedAt: Date? = nil,
        cellLookup: @Sendable (BiasCellKey) -> BiasCell?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UserRoutePreferences? {
        if preferences.alwaysShowLiveActivity, preferences.hasPinnedTransit {
            return preferences
        }
        guard preferences.autoStartLiveActivity else { return nil }
        if let plannedTripPin = preferences.plannedTripPin, !plannedTripPin.isExpired(now: now) {
            return preferences
        }

        let direction = inferredDirection(context: context, now: now, calendar: calendar)
        let accessEstimator = PersonalAccessEstimator(profile: profile, now: now, calendar: calendar)

        if preferences.hasPinnedTransit,
           hasCatchablePinnedArrival(
            preferences: preferences,
            direction: direction,
            accessEstimator: accessEstimator,
            trainArrivals: trainArrivals,
            busPredictions: busPredictions,
            metraPredictions: metraPredictions,
            vehiclePositions: vehiclePositions,
            activeAlerts: activeAlerts,
            trainsFetchedAt: trainsFetchedAt,
            cellLookup: cellLookup,
            now: now,
            calendar: calendar
           )
        {
            return preferences
        }

        let learned = learnedRoutePreferences(
            preferences: preferences,
            profile: profile,
            direction: direction,
            accessEstimator: accessEstimator,
            trainArrivals: trainArrivals,
            busPredictions: busPredictions,
            metraPredictions: metraPredictions,
            vehiclePositions: vehiclePositions,
            activeAlerts: activeAlerts,
            trainsFetchedAt: trainsFetchedAt,
            cellLookup: cellLookup,
            now: now,
            calendar: calendar
        )
        return learned
    }

    private func inferredDirection(
        context: CommuteContext,
        now: Date,
        calendar: Calendar
    ) -> CommuteDirection {
        switch context {
        case .atHome: return .toWork
        case .atWork, .elsewhere: return .toHome
        case .unknown:
            return calendar.component(.hour, from: now) < 12 ? .toWork : .toHome
        }
    }

    private func hasCatchablePinnedArrival(
        preferences: UserRoutePreferences,
        direction: CommuteDirection,
        accessEstimator: PersonalAccessEstimator,
        trainArrivals: [Arrival],
        busPredictions: [BusPrediction],
        metraPredictions: [MetraPrediction],
        vehiclePositions: [VehiclePosition],
        activeAlerts: [ServiceAlert],
        trainsFetchedAt: Date?,
        cellLookup: @Sendable (BiasCellKey) -> BiasCell?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if let line = preferences.pinnedLine {
            let stationId = preferences.pinnedStationId
            let access = accessEstimator.estimate(
                direction: direction,
                mode: .train,
                routeId: line.rawValue,
                stopId: stationId.map(String.init)
            )
            if let access {
                let arrivals = trainArrivals.filter {
                    $0.line == line && (stationId == nil || $0.stationId == stationId)
                }
                let ghosts = GhostTrainDetector().assessments(
                    for: arrivals,
                    vehiclePositions: vehiclePositions,
                    arrivalsFetchedAt: trainsFetchedAt,
                    now: now
                )
                if arrivals.contains(where: { arrival in
                    let key = BiasCellKey.make(
                        line: arrival.line.rawValue,
                        stopId: String(arrival.stopId),
                        direction: arrival.directionCode,
                        at: arrival.arrivalAt,
                        calendar: calendar
                    )
                    let score = scorer.scoreTrain(
                        arrival,
                        access: access,
                        biasCell: cellLookup(key),
                        ghost: ghosts[arrival.id],
                        alerts: activeAlerts.filtered(forLine: line, busRoute: nil),
                        now: now
                    )
                    return shouldSurface(score)
                }) {
                    return true
                }
            }
        }

        if let route = preferences.pinnedBusRoute {
            let stopId = preferences.pinnedBusStopId
            let access = accessEstimator.estimate(
                direction: direction,
                mode: .bus,
                routeId: route,
                stopId: stopId.map(String.init)
            )
            if let access {
                let predictions = busPredictions.filter {
                    $0.route == route && (stopId == nil || $0.stopId == stopId)
                }
                if predictions.contains(where: { prediction in
                    let key = BiasCellKey.make(
                        line: prediction.route,
                        stopId: String(prediction.stopId),
                        direction: prediction.directionName,
                        at: prediction.arrivalAt,
                        calendar: calendar
                    )
                    let score = scorer.scoreBus(
                        prediction,
                        access: access,
                        biasCell: cellLookup(key),
                        alerts: activeAlerts.filtered(forLine: nil, busRoute: route),
                        now: now
                    )
                    return shouldSurface(score)
                }) {
                    return true
                }
            }
        }

        if let route = preferences.pinnedMetraRoute {
            let stationId = preferences.pinnedMetraStationId
            let access = accessEstimator.estimate(
                direction: direction,
                mode: .metra,
                routeId: route,
                stopId: stationId
            )
            if let access {
                let predictions = metraPredictions.filter {
                    $0.routeId == route && (stationId == nil || $0.stationId == stationId)
                }
                if predictions.contains(where: { prediction in
                    let score = scorer.scoreMetra(
                        prediction,
                        access: access,
                        alerts: activeAlerts.filtered(forLine: nil, busRoute: nil, metraRoute: route),
                        now: now
                    )
                    return shouldSurface(score)
                }) {
                    return true
                }
            }
        }

        return false
    }

    private func learnedRoutePreferences(
        preferences: UserRoutePreferences,
        profile: MobilityProfile,
        direction: CommuteDirection,
        accessEstimator: PersonalAccessEstimator,
        trainArrivals: [Arrival],
        busPredictions: [BusPrediction],
        metraPredictions: [MetraPrediction],
        vehiclePositions: [VehiclePosition],
        activeAlerts: [ServiceAlert],
        trainsFetchedAt: Date?,
        cellLookup: @Sendable (BiasCellKey) -> BiasCell?,
        now: Date,
        calendar: Calendar
    ) -> UserRoutePreferences? {
        var best: (prefs: UserRoutePreferences, score: Double)?

        let legPatterns = profile.summary.commuteLegs(direction: direction)
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return lhs.latestSampleAt > rhs.latestSampleAt
            }
        for pattern in legPatterns {
            guard let routeId = pattern.routeId else { continue }
            var candidate = preferences
            candidate.markAutomaticPin(direction: direction, at: now)

            switch pattern.mode {
            case .train:
                guard let line = LineColor(rawValue: routeId),
                      preferences.isTrainLineVisible(line)
                else { continue }
                let stationId = pattern.stopId.flatMap(Int.init)
                candidate.pinnedLine = line
                candidate.pinnedStationId = stationId
                candidate.pinnedBusRoute = nil
                candidate.pinnedMetraRoute = nil
                let score = bestTrainScore(
                    line: line,
                    stationId: stationId,
                    direction: direction,
                    accessEstimator: accessEstimator,
                    trainArrivals: trainArrivals,
                    vehiclePositions: vehiclePositions,
                    activeAlerts: activeAlerts,
                    trainsFetchedAt: trainsFetchedAt,
                    cellLookup: cellLookup,
                    now: now,
                    calendar: calendar
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            case .bus:
                guard preferences.isBusRouteVisible(routeId) else { continue }
                candidate.pinnedLine = nil
                candidate.pinnedBusRoute = routeId
                candidate.pinnedBusDirection = nil
                candidate.pinnedBusStopId = pattern.stopId.flatMap(Int.init)
                candidate.pinnedMetraRoute = nil
                let score = bestBusScore(
                    route: routeId,
                    stopId: pattern.stopId.flatMap(Int.init),
                    direction: direction,
                    accessEstimator: accessEstimator,
                    busPredictions: busPredictions,
                    activeAlerts: activeAlerts,
                    cellLookup: cellLookup,
                    now: now,
                    calendar: calendar
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            case .metra:
                guard preferences.isMetraRouteVisible(routeId) else { continue }
                candidate.pinnedLine = nil
                candidate.pinnedBusRoute = nil
                candidate.pinnedMetraRoute = routeId
                candidate.pinnedMetraStationId = pattern.stopId
                candidate.pinnedMetraDirectionId = nil
                let score = bestMetraScore(
                    route: routeId,
                    stationId: pattern.stopId,
                    direction: direction,
                    accessEstimator: accessEstimator,
                    metraPredictions: metraPredictions,
                    activeAlerts: activeAlerts,
                    now: now
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            case .divvy:
                continue
            }
        }

        let patterns = profile.summary.patterns(direction: direction)
            .sorted { lhs, rhs in
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return lhs.latestSampleAt > rhs.latestSampleAt
            }

        for pattern in patterns {
            var candidate = preferences
            candidate.markAutomaticPin(direction: direction, at: now)

            switch pattern.mode {
            case .train:
                guard let line = LineColor(rawValue: pattern.routeId),
                      preferences.isTrainLineVisible(line)
                else { continue }
                let stationId = pattern.topStationId.flatMap(Int.init)
                candidate.pinnedLine = line
                candidate.pinnedStationId = stationId
                candidate.pinnedBusRoute = nil
                candidate.pinnedMetraRoute = nil
                let score = bestTrainScore(
                    line: line,
                    stationId: stationId,
                    direction: direction,
                    accessEstimator: accessEstimator,
                    trainArrivals: trainArrivals,
                    vehiclePositions: vehiclePositions,
                    activeAlerts: activeAlerts,
                    trainsFetchedAt: trainsFetchedAt,
                    cellLookup: cellLookup,
                    now: now,
                    calendar: calendar
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            case .bus:
                guard preferences.isBusRouteVisible(pattern.routeId) else { continue }
                candidate.pinnedLine = nil
                candidate.pinnedBusRoute = pattern.routeId
                candidate.pinnedBusDirection = pattern.topDirectionLabel
                candidate.pinnedBusStopId = nil
                candidate.pinnedMetraRoute = nil
                let score = bestBusScore(
                    route: pattern.routeId,
                    stopId: nil,
                    direction: direction,
                    accessEstimator: accessEstimator,
                    busPredictions: busPredictions,
                    activeAlerts: activeAlerts,
                    cellLookup: cellLookup,
                    now: now,
                    calendar: calendar
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            case .metra:
                guard preferences.isMetraRouteVisible(pattern.routeId) else { continue }
                candidate.pinnedLine = nil
                candidate.pinnedBusRoute = nil
                candidate.pinnedMetraRoute = pattern.routeId
                candidate.pinnedMetraStationId = pattern.topStationId
                candidate.pinnedMetraDirectionId = pattern.topDirectionLabel.flatMap(Int.init)
                let score = bestMetraScore(
                    route: pattern.routeId,
                    stationId: pattern.topStationId,
                    direction: direction,
                    accessEstimator: accessEstimator,
                    metraPredictions: metraPredictions,
                    activeAlerts: activeAlerts,
                    now: now
                )
                if let score, shouldSurface(score) {
                    best = chooseBest(best, candidate: (candidate, score.score))
                }
            }
        }

        return best?.prefs
    }

    private func chooseBest(
        _ current: (prefs: UserRoutePreferences, score: Double)?,
        candidate: (prefs: UserRoutePreferences, score: Double)
    ) -> (prefs: UserRoutePreferences, score: Double) {
        guard let current else { return candidate }
        return candidate.score > current.score ? candidate : current
    }

    private func bestTrainScore(
        line: LineColor,
        stationId: Int?,
        direction: CommuteDirection,
        accessEstimator: PersonalAccessEstimator,
        trainArrivals: [Arrival],
        vehiclePositions: [VehiclePosition],
        activeAlerts: [ServiceAlert],
        trainsFetchedAt: Date?,
        cellLookup: @Sendable (BiasCellKey) -> BiasCell?,
        now: Date,
        calendar: Calendar
    ) -> TransitOpportunityScore? {
        let access = accessEstimator.estimate(
            direction: direction,
            mode: .train,
            routeId: line.rawValue,
            stopId: stationId.map(String.init)
        )
        guard access != nil else { return nil }
        let arrivals = trainArrivals.filter {
            $0.line == line && (stationId == nil || $0.stationId == stationId)
        }
        let ghosts = GhostTrainDetector().assessments(
            for: arrivals,
            vehiclePositions: vehiclePositions,
            arrivalsFetchedAt: trainsFetchedAt,
            now: now
        )
        return arrivals
            .map { arrival in
                let key = BiasCellKey.make(
                    line: arrival.line.rawValue,
                    stopId: String(arrival.stopId),
                    direction: arrival.directionCode,
                    at: arrival.arrivalAt,
                    calendar: calendar
                )
                return scorer.scoreTrain(
                    arrival,
                    access: access,
                    biasCell: cellLookup(key),
                    ghost: ghosts[arrival.id],
                    alerts: activeAlerts.filtered(forLine: line, busRoute: nil),
                    now: now
                )
            }
            .max { $0.score < $1.score }
    }

    private func bestBusScore(
        route: String,
        stopId: Int?,
        direction: CommuteDirection,
        accessEstimator: PersonalAccessEstimator,
        busPredictions: [BusPrediction],
        activeAlerts: [ServiceAlert],
        cellLookup: @Sendable (BiasCellKey) -> BiasCell?,
        now: Date,
        calendar: Calendar
    ) -> TransitOpportunityScore? {
        let access = accessEstimator.estimate(
            direction: direction,
            mode: .bus,
            routeId: route,
            stopId: stopId.map(String.init)
        )
        guard access != nil else { return nil }
        return busPredictions
            .filter { $0.route == route && (stopId == nil || $0.stopId == stopId) }
            .map { prediction in
                let key = BiasCellKey.make(
                    line: prediction.route,
                    stopId: String(prediction.stopId),
                    direction: prediction.directionName,
                    at: prediction.arrivalAt,
                    calendar: calendar
                )
                return scorer.scoreBus(
                    prediction,
                    access: access,
                    biasCell: cellLookup(key),
                    alerts: activeAlerts.filtered(forLine: nil, busRoute: route),
                    now: now
                )
            }
            .max { $0.score < $1.score }
    }

    private func bestMetraScore(
        route: String,
        stationId: String?,
        direction: CommuteDirection,
        accessEstimator: PersonalAccessEstimator,
        metraPredictions: [MetraPrediction],
        activeAlerts: [ServiceAlert],
        now: Date
    ) -> TransitOpportunityScore? {
        let access = accessEstimator.estimate(
            direction: direction,
            mode: .metra,
            routeId: route,
            stopId: stationId
        )
        guard access != nil else { return nil }
        return metraPredictions
            .filter { $0.routeId == route && (stationId == nil || $0.stationId == stationId) }
            .map {
                scorer.scoreMetra(
                    $0,
                    access: access,
                    alerts: activeAlerts.filtered(forLine: nil, busRoute: nil, metraRoute: route),
                    now: now
                )
            }
            .max { $0.score < $1.score }
    }

    private func shouldSurface(_ score: TransitOpportunityScore) -> Bool {
        switch score.catchability {
        case .comfortable, .tight:
            return score.score >= 0.42
        case .unknown, .distant, .past, .tooSoon:
            return false
        }
    }
}
