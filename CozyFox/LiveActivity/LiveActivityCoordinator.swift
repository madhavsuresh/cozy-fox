import Foundation
@preconcurrency import ActivityKit
import TransitCache
import TransitDomain
import TransitModels

/// Manages a **single combined Live Activity** that can render either, both,
/// or neither of a pinned train leg and a pinned bus leg. Combined into one
/// activity (vs. two separate ones) so the Dynamic Island shows both legs at
/// the same time instead of cycling between them.
actor LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    struct QuietRelevanceContext: Sendable {
        let profile: MobilityProfile
        let currentContext: CommuteContext
        let biasCells: [BiasCellKey: BiasCell]
        let trainsFetchedAt: Date?
        let calendar: Calendar

        init(
            profile: MobilityProfile,
            currentContext: CommuteContext,
            biasCells: [BiasCellKey: BiasCell],
            trainsFetchedAt: Date?,
            calendar: Calendar = .current
        ) {
            self.profile = profile
            self.currentContext = currentContext
            self.biasCells = biasCells
            self.trainsFetchedAt = trainsFetchedAt
            self.calendar = calendar
        }
    }

    private var current: Activity<CommuteAttributes>?
    private var safetyTimeout: Task<Void, Never>?
    private var isPersistent: Bool = false

    // MARK: - Always-on mode

    func ensureRunning(
        snapshot: TransitSnapshot,
        prefs: UserRoutePreferences,
        relevance: QuietRelevanceContext? = nil
    ) async {
        guard prefs.alwaysShowLiveActivity else {
            await endCurrentIfNeeded()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let trainLeg = makeTrainLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)
        let busLeg = makeBusLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)
        let metraLeg = makeMetraLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)

        // Nothing to surface → tear down.
        guard trainLeg != nil || busLeg != nil else {
            await endCurrentIfNeeded()
            return
        }

        let identity = makeIdentity(prefs: prefs)
        let state = CommuteAttributes.ContentState(train: trainLeg, bus: busLeg, metra: metraLeg)
        // Stale at the soonest arrival itself (no grace) so iOS marks the
        // activity stale the moment its currently-published next arrival
        // passes — the on-screen number is no longer authoritative.
        let staleDate = soonestArrival(train: trainLeg, bus: busLeg, metra: metraLeg)

        if let activity = current,
           activity.attributes.trainIdentity == identity.train,
           activity.attributes.busIdentity == identity.bus,
           activity.attributes.metraIdentity == identity.metra
        {
            // Same legs being tracked — just push new state.
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        } else {
            // Identity changed (user repinned, or first start) — restart.
            await endCurrentIfNeeded()
            await startInternal(identity: identity, state: state, staleDate: staleDate, persistent: true)
        }
    }

    // MARK: - Quiet relevance mode

    func ensureRelevant(
        snapshot: TransitSnapshot,
        prefs: UserRoutePreferences,
        relevance: QuietRelevanceContext
    ) async {
        guard !prefs.alwaysShowLiveActivity else {
            await ensureRunning(snapshot: snapshot, prefs: prefs, relevance: relevance)
            return
        }
        guard prefs.autoStartLiveActivity else {
            await endCurrentIfNeeded()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let trainLeg = makeTrainLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)
        let busLeg = makeBusLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)
        let metraLeg = makeMetraLeg(prefs: prefs, snapshot: snapshot, relevance: relevance)

        guard trainLeg != nil || busLeg != nil else {
            await endCurrentIfNeeded()
            return
        }

        let identity = makeIdentity(prefs: prefs)
        let state = CommuteAttributes.ContentState(train: trainLeg, bus: busLeg, metra: metraLeg)
        let staleDate = soonestArrival(train: trainLeg, bus: busLeg, metra: metraLeg)

        if let activity = current,
           activity.attributes.trainIdentity == identity.train,
           activity.attributes.busIdentity == identity.bus,
           activity.attributes.metraIdentity == identity.metra
        {
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        } else {
            await endCurrentIfNeeded()
            await startInternal(identity: identity, state: state, staleDate: staleDate, persistent: false)
        }
    }

    // MARK: - Identity & leg builders

    private func makeIdentity(prefs: UserRoutePreferences) -> (train: String?, bus: String?, metra: String?) {
        var trainId: String?
        if let tripPin = prefs.plannedTripPin, !tripPin.trainLegs.isEmpty {
            let pieces = tripPin.trainLegs.map { tripTrain in
                [
                    tripTrain.stationId.map(String.init),
                    tripTrain.destinationName,
                    tripTrain.line.rawValue
                ].compactMap { $0 }.joined(separator: "-")
            }
            trainId = ([tripPin.id.uuidString] + pieces).joined(separator: "|")
        } else if prefs.pinnedLine != nil {
            // Use mapId + destination if we know them, else just "<line>"
            let parts: [String] = [
                prefs.pinnedStationId.map { "\($0)" },
                prefs.pinnedTrainDestination,
                prefs.pinnedLine?.rawValue
            ].compactMap { $0 }
            trainId = parts.joined(separator: "-")
        }
        var busId: String?
        if let tripPin = prefs.plannedTripPin, !tripPin.busLegs.isEmpty {
            let pieces = tripPin.busLegs.map { tripBus in
                [
                    tripBus.route,
                    tripBus.directionLabel,
                    tripBus.stopId.map(String.init)
                ].compactMap { $0 }.joined(separator: "-")
            }
            busId = ([tripPin.id.uuidString] + pieces).joined(separator: "|")
        } else if let route = prefs.pinnedBusRoute {
            busId = [
                route,
                prefs.pinnedBusDirection,
                prefs.pinnedBusStopId.map(String.init)
            ].compactMap { $0 }.joined(separator: "-")
        }
        var metraId: String?
        if let tripPin = prefs.plannedTripPin, !tripPin.metraLegs.isEmpty {
            let pieces = tripPin.metraLegs.map { tripMetra in
                [
                    tripMetra.routeId,
                    tripMetra.stationId,
                    tripMetra.destinationName
                ].compactMap { $0 }.joined(separator: "-")
            }
            metraId = ([tripPin.id.uuidString] + pieces).joined(separator: "|")
        } else if let route = prefs.pinnedMetraRoute {
            metraId = [
                route,
                prefs.pinnedMetraStationId,
                prefs.pinnedMetraDirectionId.map(String.init),
                prefs.pinnedMetraDestination
            ].compactMap { $0 }.joined(separator: "-")
        }
        return (trainId, busId, metraId)
    }

    private func makeTrainLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.TrainLeg? {
        // Prefer the pinned line if present; else first tracked; else nothing
        // (we don't auto-fill a "fallback" arrival when only bus is pinned).
        if let tripPin = prefs.plannedTripPin, !tripPin.trainLegs.isEmpty {
            return tripPin.trainLegs
                .compactMap { makeTripTrainLeg($0, snapshot: snapshot, relevance: relevance) }
                .min { $0.nextArrival < $1.nextArrival }
        }

        let line: LineColor
        if let pinned = prefs.pinnedLine {
            line = pinned
        } else if let tracked = prefs.trains.first {
            line = tracked.line
        } else if prefs.pinnedBusRoute == nil,
                  let arrival = snapshot.trainArrivals.first
        {
            // No pins at all → fall back to first arrival anywhere so the
            // user sees *something* on first launch.
            line = arrival.line
        } else {
            return nil
        }

        var arrivals = snapshot.trainArrivals.filter { $0.line == line }
        if let stationId = prefs.pinnedStationId {
            arrivals = arrivals.filter { $0.stationId == stationId }
        }
        if let destination = prefs.pinnedTrainDestination {
            arrivals = arrivals.filter { $0.destinationName == destination }
        }
        // Drop already-departed predictions so the published `nextArrival`
        // and `upcomingArrivals` are all in the future — keeps the Live
        // Activity countdown and dot strip in agreement at publish time.
        let now = Date()
        let sorted = orderedTrainArrivals(
            arrivals,
            line: line,
            stationId: prefs.pinnedStationId,
            prefs: prefs,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
        return CommuteAttributes.TrainLeg(
            routeLabel: line.displayName,
            lineColorRaw: line.rawValue,
            stopName: first.arrival.stationName,
            destination: first.arrival.destinationName,
            nextArrival: first.arrival.arrivalAt,
            followingArrival: following?.arrival.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.arrival.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func makeTripTrainLeg(
        _ tripTrain: PlannedTripPin.TrainLeg,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.TrainLeg? {
        var arrivals = snapshot.trainArrivals.filter { $0.line == tripTrain.line }
        if let stationId = tripTrain.stationId {
            arrivals = arrivals.filter { $0.stationId == stationId }
        }
        if let destination = tripTrain.destinationName {
            arrivals = arrivals.filter { $0.destinationName == destination }
        }
        let now = Date()
        let sorted = orderedTrainArrivals(
            arrivals,
            line: tripTrain.line,
            stationId: tripTrain.stationId,
            prefs: .empty,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        return CommuteAttributes.TrainLeg(
            routeLabel: tripTrain.line.displayName,
            lineColorRaw: tripTrain.line.rawValue,
            stopName: tripTrain.stationName,
            destination: first.arrival.destinationName,
            nextArrival: first.arrival.arrivalAt,
            followingArrival: sorted.dropFirst().first?.arrival.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: tripTrain.line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.arrival.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func makeBusLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.BusLeg? {
        if let tripPin = prefs.plannedTripPin, !tripPin.busLegs.isEmpty {
            return tripPin.busLegs
                .compactMap { makeTripBusLeg($0, snapshot: snapshot, relevance: relevance) }
                .min { $0.nextArrival < $1.nextArrival }
        }

        guard let route = prefs.pinnedBusRoute else { return nil }
        var predictions = snapshot.busPredictions.filter { $0.route == route }
        if let direction = prefs.pinnedBusDirection {
            predictions = predictions.filter { $0.directionName == direction }
        }
        if let stopId = prefs.pinnedBusStopId {
            predictions = predictions.filter { $0.stopId == stopId }
        }
        let now = Date()
        let sorted = orderedBusPredictions(
            predictions,
            route: route,
            stopId: prefs.pinnedBusStopId,
            prefs: prefs,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
        return CommuteAttributes.BusLeg(
            routeLabel: "Route \(route)",
            stopName: first.prediction.stopName,
            directionLabel: prefs.pinnedBusDirection ?? first.prediction.directionName,
            destination: first.prediction.destinationName,
            nextArrival: first.prediction.arrivalAt,
            followingArrival: following?.prediction.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: route)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.prediction.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func makeTripBusLeg(
        _ tripBus: PlannedTripPin.BusLeg,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.BusLeg? {
        var predictions = snapshot.busPredictions.filter { $0.route == tripBus.route }
        if let direction = tripBus.directionLabel {
            predictions = predictions.filter { $0.directionName == direction }
        }
        if let stopId = tripBus.stopId {
            predictions = predictions.filter { $0.stopId == stopId }
        }
        let now = Date()
        let sorted = orderedBusPredictions(
            predictions,
            route: tripBus.route,
            stopId: tripBus.stopId,
            prefs: .empty,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        return CommuteAttributes.BusLeg(
            routeLabel: "Route \(tripBus.route)",
            stopName: tripBus.stopName,
            directionLabel: tripBus.directionLabel ?? first.prediction.directionName,
            destination: first.prediction.destinationName,
            nextArrival: first.prediction.arrivalAt,
            followingArrival: sorted.dropFirst().first?.prediction.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: tripBus.route)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.prediction.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func makeMetraLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.MetraLeg? {
        if let tripPin = prefs.plannedTripPin, !tripPin.metraLegs.isEmpty {
            return tripPin.metraLegs
                .compactMap { makeTripMetraLeg($0, snapshot: snapshot, relevance: relevance) }
                .min { $0.nextArrival < $1.nextArrival }
        }

        guard let route = prefs.pinnedMetraRoute else { return nil }
        var predictions = snapshot.metraPredictions.filter { $0.routeId == route }
        if let stationId = prefs.pinnedMetraStationId {
            predictions = predictions.filter { $0.stationId == stationId }
        }
        if let directionId = prefs.pinnedMetraDirectionId {
            predictions = predictions.filter { $0.directionId == directionId }
        }
        if let destination = prefs.pinnedMetraDestination {
            predictions = predictions.filter { $0.destinationName == destination }
        }
        let now = Date()
        let sorted = orderedMetraPredictions(
            predictions,
            route: route,
            stationId: prefs.pinnedMetraStationId,
            prefs: prefs,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        let routeLabel = MetraStationCatalog.route(id: route)?.shortName ?? route
        return CommuteAttributes.MetraLeg(
            routeLabel: routeLabel,
            routeId: route,
            stopName: first.prediction.stationName,
            destination: first.prediction.destinationName,
            nextArrival: first.prediction.arrivalAt,
            followingArrival: sorted.dropFirst().first?.prediction.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: nil, metraRoute: route)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.prediction.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func makeTripMetraLeg(
        _ tripMetra: PlannedTripPin.MetraLeg,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?
    ) -> CommuteAttributes.MetraLeg? {
        var predictions = snapshot.metraPredictions.filter { $0.routeId == tripMetra.routeId }
        if let stationId = tripMetra.stationId {
            predictions = predictions.filter { $0.stationId == stationId }
        }
        if let directionId = tripMetra.directionId {
            predictions = predictions.filter { $0.directionId == directionId }
        }
        if let destination = tripMetra.destinationName {
            predictions = predictions.filter { $0.destinationName == destination }
        }
        let now = Date()
        let sorted = orderedMetraPredictions(
            predictions,
            route: tripMetra.routeId,
            stationId: tripMetra.stationId,
            prefs: .empty,
            snapshot: snapshot,
            relevance: relevance,
            now: now
        )
        guard let first = sorted.first else { return nil }
        let routeLabel = MetraStationCatalog.route(id: tripMetra.routeId)?.shortName ?? tripMetra.routeId
        return CommuteAttributes.MetraLeg(
            routeLabel: routeLabel,
            routeId: tripMetra.routeId,
            stopName: tripMetra.stationName,
            destination: first.prediction.destinationName,
            nextArrival: first.prediction.arrivalAt,
            followingArrival: sorted.dropFirst().first?.prediction.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: nil, metraRoute: tripMetra.routeId)
                .first?.headline,
            upcomingArrivals: sorted.prefix(6).map(\.prediction.arrivalAt),
            confidenceMarks: sorted.prefix(6).compactMap { $0.score?.confidenceMark }
        )
    }

    private func orderedTrainArrivals(
        _ arrivals: [Arrival],
        line: LineColor,
        stationId: Int?,
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?,
        now: Date
    ) -> [(arrival: Arrival, score: TransitOpportunityScore?)] {
        let future = arrivals.filter { $0.arrivalAt > now }
        guard let relevance else {
            return future
                .sorted { $0.arrivalAt < $1.arrivalAt }
                .map { ($0, nil) }
        }

        let direction = inferredDirection(prefs: prefs, relevance: relevance, now: now)
        let access = PersonalAccessEstimator(
            profile: relevance.profile,
            now: now,
            calendar: relevance.calendar
        )
        .estimate(
            direction: direction,
            mode: .train,
            routeId: line.rawValue,
            stopId: stationId.map(String.init)
        )
        let ghosts = GhostTrainDetector().assessments(
            for: future,
            vehiclePositions: snapshot.vehiclePositions,
            arrivalsFetchedAt: relevance.trainsFetchedAt,
            now: now
        )
        let alerts = snapshot.activeAlerts.filtered(forLine: line, busRoute: nil)
        let scorer = TransitOpportunityScorer()
        let scored: [(arrival: Arrival, score: TransitOpportunityScore)] = future.map { arrival in
            let key = BiasCellKey.make(
                line: arrival.line.rawValue,
                stopId: String(arrival.stopId),
                direction: arrival.directionCode,
                at: arrival.arrivalAt,
                calendar: relevance.calendar
            )
            let score = scorer.scoreTrain(
                arrival,
                access: access,
                biasCell: relevance.biasCells[key],
                ghost: ghosts[arrival.id],
                alerts: alerts,
                now: now
            )
            return (arrival, score)
        }

        guard shouldUseQuietScores(scored.map(\.score)) else {
            return scored
                .sorted { $0.arrival.arrivalAt < $1.arrival.arrivalAt }
                .map { ($0.arrival, $0.score) }
        }
        return scored
            .sorted {
                if abs($0.score.score - $1.score.score) > 0.04 {
                    return $0.score.score > $1.score.score
                }
                return $0.score.adjustedArrivalAt < $1.score.adjustedArrivalAt
            }
            .map { ($0.arrival, $0.score) }
    }

    private func orderedBusPredictions(
        _ predictions: [BusPrediction],
        route: String,
        stopId: Int?,
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?,
        now: Date
    ) -> [(prediction: BusPrediction, score: TransitOpportunityScore?)] {
        let future = predictions.filter { $0.arrivalAt > now }
        guard let relevance else {
            return future
                .sorted { $0.arrivalAt < $1.arrivalAt }
                .map { ($0, nil) }
        }

        let direction = inferredDirection(prefs: prefs, relevance: relevance, now: now)
        let access = PersonalAccessEstimator(
            profile: relevance.profile,
            now: now,
            calendar: relevance.calendar
        )
        .estimate(
            direction: direction,
            mode: .bus,
            routeId: route,
            stopId: stopId.map(String.init)
        )
        let alerts = snapshot.activeAlerts.filtered(forLine: nil, busRoute: route)
        let scorer = TransitOpportunityScorer()
        let scored: [(prediction: BusPrediction, score: TransitOpportunityScore)] = future.map { prediction in
            let key = BiasCellKey.make(
                line: prediction.route,
                stopId: String(prediction.stopId),
                direction: prediction.directionName,
                at: prediction.arrivalAt,
                calendar: relevance.calendar
            )
            let score = scorer.scoreBus(
                prediction,
                access: access,
                biasCell: relevance.biasCells[key],
                alerts: alerts,
                now: now
            )
            return (prediction, score)
        }

        guard shouldUseQuietScores(scored.map(\.score)) else {
            return scored
                .sorted { $0.prediction.arrivalAt < $1.prediction.arrivalAt }
                .map { ($0.prediction, $0.score) }
        }
        return scored
            .sorted {
                if abs($0.score.score - $1.score.score) > 0.04 {
                    return $0.score.score > $1.score.score
                }
                return $0.score.adjustedArrivalAt < $1.score.adjustedArrivalAt
            }
            .map { ($0.prediction, $0.score) }
    }

    private func orderedMetraPredictions(
        _ predictions: [MetraPrediction],
        route: String,
        stationId: String?,
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        relevance: QuietRelevanceContext?,
        now: Date
    ) -> [(prediction: MetraPrediction, score: TransitOpportunityScore?)] {
        let future = predictions.filter { $0.arrivalAt > now }
        guard let relevance else {
            return future
                .sorted { $0.arrivalAt < $1.arrivalAt }
                .map { ($0, nil) }
        }

        let direction = inferredDirection(prefs: prefs, relevance: relevance, now: now)
        let access = PersonalAccessEstimator(
            profile: relevance.profile,
            now: now,
            calendar: relevance.calendar
        )
        .estimate(
            direction: direction,
            mode: .metra,
            routeId: route,
            stopId: stationId
        )
        let alerts = snapshot.activeAlerts.filtered(forLine: nil, busRoute: nil, metraRoute: route)
        let scorer = TransitOpportunityScorer()
        let scored: [(prediction: MetraPrediction, score: TransitOpportunityScore)] = future.map {
            let score = scorer.scoreMetra(
                $0,
                access: access,
                alerts: alerts,
                now: now
            )
            return ($0, score)
        }

        guard shouldUseQuietScores(scored.map(\.score)) else {
            return scored
                .sorted { $0.prediction.arrivalAt < $1.prediction.arrivalAt }
                .map { ($0.prediction, $0.score) }
        }
        return scored
            .sorted {
                if abs($0.score.score - $1.score.score) > 0.04 {
                    return $0.score.score > $1.score.score
                }
                return $0.score.adjustedArrivalAt < $1.score.adjustedArrivalAt
            }
            .map { ($0.prediction, $0.score) }
    }

    private func inferredDirection(
        prefs: UserRoutePreferences,
        relevance: QuietRelevanceContext,
        now: Date
    ) -> CommuteDirection {
        if let direction = prefs.autoPinnedDirection {
            return direction
        }
        switch relevance.currentContext {
        case .atHome:
            return .toWork
        case .atWork, .elsewhere:
            return .toHome
        case .unknown:
            return relevance.calendar.component(.hour, from: now) < 12 ? .toWork : .toHome
        }
    }

    private func shouldUseQuietScores(_ scores: [TransitOpportunityScore]) -> Bool {
        scores.contains { score in
            guard score.confidence >= 0.35 else { return false }
            switch score.catchability {
            case .tight, .comfortable, .distant, .tooSoon:
                return true
            case .unknown, .past:
                return false
            }
        }
    }

    private func soonestArrival(
        train: CommuteAttributes.TrainLeg?,
        bus: CommuteAttributes.BusLeg?,
        metra: CommuteAttributes.MetraLeg? = nil
    ) -> Date {
        let dates = [train?.nextArrival, bus?.nextArrival, metra?.nextArrival].compactMap { $0 }
        return dates.min() ?? Date().addingTimeInterval(600)
    }

    // MARK: - Region-exit start (legacy "auto-start on leaving home/work")

    func startCommute(for preference: TrainPreference, snapshot: TransitSnapshot) async {
        await endCurrentIfNeeded()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let now = Date()
        let upcoming = snapshot.trainArrivals
            .filter { $0.line == preference.line }
            .filter { $0.stationId == preference.mapId || preference.mapId == 0 }
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = upcoming.first
        let trainLeg = CommuteAttributes.TrainLeg(
            routeLabel: preference.line.displayName,
            lineColorRaw: preference.line.rawValue,
            stopName: preference.stationName,
            destination: first?.destinationName ?? preference.directionLabel,
            nextArrival: first?.arrivalAt ?? now.addingTimeInterval(600),
            followingArrival: upcoming.dropFirst().first?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: preference.line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: upcoming.prefix(6).map(\.arrivalAt)
        )

        let state = CommuteAttributes.ContentState(train: trainLeg, bus: nil, metra: nil)
        let staleDate = trainLeg.nextArrival
        await startInternal(
            identity: (train: "\(preference.mapId)-\(trainLeg.destination)", bus: nil, metra: nil),
            state: state,
            staleDate: staleDate,
            persistent: false
        )
    }

    // MARK: - Internals

    private func startInternal(
        identity: (train: String?, bus: String?, metra: String?),
        state: CommuteAttributes.ContentState,
        staleDate: Date,
        persistent: Bool
    ) async {
        let attributes = CommuteAttributes(
            trainIdentity: identity.train,
            busIdentity: identity.bus,
            metraIdentity: identity.metra
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate),
                pushType: nil
            )
            current = activity
            isPersistent = persistent
            safetyTimeout?.cancel()
            if !persistent {
                safetyTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 90 * 60 * 1_000_000_000)
                    await self?.endCurrentIfNeeded()
                }
            }
        } catch {
            // Live Activities unavailable — silently skip.
        }
    }

    func endCurrentIfNeeded() async {
        if let activity = current {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
        current = nil
        isPersistent = false
        safetyTimeout?.cancel()
        safetyTimeout = nil
    }
}
