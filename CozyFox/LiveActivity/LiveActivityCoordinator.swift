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

    private var current: Activity<CommuteAttributes>?
    private var safetyTimeout: Task<Void, Never>?
    private var isPersistent: Bool = false

    // MARK: - Always-on mode

    func ensureRunning(
        snapshot: TransitSnapshot,
        prefs: UserRoutePreferences,
        portfolioRecommendations: [UUID: PortfolioRecommendation] = [:],
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) async {
        guard prefs.alwaysShowLiveActivity else {
            await endCurrentIfNeeded()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Phase 6: portfolio recommendations supersede single-pin /
        // planned-trip-pin sources when present. When a portfolio
        // source covers some modes but not others, the un-covered
        // modes stay empty rather than mixing portfolio + single-pin
        // — keeps the on-screen surface coherent with what the user
        // picked.
        let portfolioSource = resolvePortfolioSource(
            prefs: prefs,
            recommendations: portfolioRecommendations,
            snapshot: snapshot,
            biasCells: biasCells
        )

        let trainLeg: CommuteAttributes.TrainLeg?
        let busLeg: CommuteAttributes.BusLeg?
        if let portfolioSource {
            trainLeg = portfolioSource.train
            busLeg = portfolioSource.bus
        } else {
            trainLeg = makeTrainLeg(prefs: prefs, snapshot: snapshot, biasCells: biasCells)
            busLeg = makeBusLeg(prefs: prefs, snapshot: snapshot, biasCells: biasCells)
        }
        // Metra Live Activity rendering is temporarily disabled; pinned
        // Metra still appears in the app and widgets.
        let metraLeg: CommuteAttributes.MetraLeg? = nil

        // Nothing to surface → tear down.
        guard trainLeg != nil || busLeg != nil else {
            await endCurrentIfNeeded()
            return
        }

        let identity = makeIdentity(prefs: prefs, portfolioSource: portfolioSource)
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

    // MARK: - Identity & leg builders

    private func makeIdentity(
        prefs: UserRoutePreferences,
        portfolioSource: PortfolioSource? = nil
    ) -> (train: String?, bus: String?, metra: String?) {
        // Portfolio source completely supersedes prefs-based identity —
        // any leg the portfolio doesn't fill stays nil rather than
        // falling back to single-pin, so the activity restarts cleanly
        // when the user transitions from "single pin" to "portfolio
        // recommendation" and back.
        if let portfolioSource {
            let prefix = "portfolio-\(portfolioSource.portfolioID.uuidString)-\(portfolioSource.optionID.uuidString)"
            let trainId: String? = portfolioSource.train.map {
                "\(prefix)|train|\($0.lineColorRaw)|\($0.stopName)|\($0.destination)"
            }
            let busId: String? = portfolioSource.bus.map {
                "\(prefix)|bus|\($0.routeLabel)|\($0.stopName)|\($0.directionLabel)"
            }
            return (trainId, busId, nil)
        }
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
            // For the Live Activity's stable identity string, fold a
            // multi-destination pin into a single canonical token
            // (sorted + joined) so the same set always produces the
            // same id regardless of selection order.
            let destinationsToken = prefs.pinnedTrainDestinations
                .map { $0.sorted().joined(separator: ",") }
            let parts: [String] = [
                prefs.pinnedStationId.map { "\($0)" },
                destinationsToken,
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
        let metraId: String? = nil
        return (trainId, busId, metraId)
    }

    private func makeTrainLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.TrainLeg? {
        // Prefer the pinned line if present; else first tracked; else nothing
        // (we don't auto-fill a "fallback" arrival when only bus is pinned).
        if let tripPin = prefs.plannedTripPin, !tripPin.trainLegs.isEmpty {
            return tripPin.trainLegs
                .compactMap { makeTripTrainLeg($0, snapshot: snapshot, biasCells: biasCells) }
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
        if let destinations = prefs.pinnedTrainDestinations {
            arrivals = arrivals.filter { destinations.contains($0.destinationName) }
        }
        // Drop already-departed predictions so the published `nextArrival`
        // and `upcomingArrivals` are all in the future — keeps the Live
        // Activity countdown and dot strip in agreement at publish time.
        let now = Date()
        let sorted = arrivals
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.TrainLeg(
            routeLabel: line.displayName,
            lineColorRaw: line.rawValue,
            stopName: first.stationName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: following?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.trainMarks(arrivals: upcoming, biasCells: biasCells)
        )
    }

    private func makeTripTrainLeg(
        _ tripTrain: PlannedTripPin.TrainLeg,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.TrainLeg? {
        var arrivals = snapshot.trainArrivals.filter { $0.line == tripTrain.line }
        if let stationId = tripTrain.stationId {
            arrivals = arrivals.filter { $0.stationId == stationId }
        }
        if let destination = tripTrain.destinationName {
            arrivals = arrivals.filter { $0.destinationName == destination }
        }
        let now = Date()
        let sorted = arrivals
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.TrainLeg(
            routeLabel: tripTrain.line.displayName,
            lineColorRaw: tripTrain.line.rawValue,
            stopName: tripTrain.stationName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: sorted.dropFirst().first?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: tripTrain.line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.trainMarks(arrivals: upcoming, biasCells: biasCells)
        )
    }

    private func makeBusLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.BusLeg? {
        if let tripPin = prefs.plannedTripPin, !tripPin.busLegs.isEmpty {
            return tripPin.busLegs
                .compactMap { makeTripBusLeg($0, snapshot: snapshot, biasCells: biasCells) }
                .min { $0.nextArrival < $1.nextArrival }
        }

        guard let route = prefs.pinnedBusRoute else { return nil }
        var predictions = BusPredictionCalibrator
            .displayableCalibratedPredictions(
                from: snapshot.busPredictions,
                vehicles: snapshot.vehiclePositions,
                activeDetours: snapshot.busDetours,
                patterns: snapshot.busPatterns,
                stopDetourStates: snapshot.busStopDetourStates,
                bins: snapshot.busResidualBins
            )
            .filter { $0.route == route }
        if let direction = prefs.pinnedBusDirection {
            predictions = predictions.filter { $0.directionName == direction }
        }
        if let stopId = prefs.pinnedBusStopId {
            predictions = predictions.filter { $0.stopId == stopId }
        }
        let now = Date()
        let sorted = predictions
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.BusLeg(
            routeLabel: "Route \(route)",
            stopName: first.stopName,
            directionLabel: prefs.pinnedBusDirection ?? first.directionName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: following?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: route)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.busMarks(predictions: upcoming, biasCells: biasCells)
        )
    }

    private func makeTripBusLeg(
        _ tripBus: PlannedTripPin.BusLeg,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.BusLeg? {
        var predictions = BusPredictionCalibrator
            .displayableCalibratedPredictions(
                from: snapshot.busPredictions,
                vehicles: snapshot.vehiclePositions,
                activeDetours: snapshot.busDetours,
                patterns: snapshot.busPatterns,
                stopDetourStates: snapshot.busStopDetourStates,
                bins: snapshot.busResidualBins
            )
            .filter { $0.route == tripBus.route }
        if let direction = tripBus.directionLabel {
            predictions = predictions.filter { $0.directionName == direction }
        }
        if let stopId = tripBus.stopId {
            predictions = predictions.filter { $0.stopId == stopId }
        }
        let now = Date()
        let sorted = predictions
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.BusLeg(
            routeLabel: "Route \(tripBus.route)",
            stopName: tripBus.stopName,
            directionLabel: tripBus.directionLabel ?? first.directionName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: sorted.dropFirst().first?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: tripBus.route)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.busMarks(predictions: upcoming, biasCells: biasCells)
        )
    }

    // MARK: - Confidence marks

    /// Chicago-local calendar for `BiasCellKey.make(at:calendar:)` so the
    /// per-hour bias buckets line up with how `ArrivalGrader` recorded
    /// them.
    private static let chicagoCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar
    }()

    static func trainMarks(
        arrivals: [Arrival],
        biasCells: [BiasCellKey: BiasCell]
    ) -> [ArrivalConfidenceMark] {
        arrivals.map { arrival in
            let key = BiasCellKey.make(
                line: arrival.line.rawValue,
                stopId: String(arrival.stopId),
                direction: arrival.directionCode,
                at: arrival.arrivalAt,
                calendar: chicagoCalendar
            )
            return ArrivalConfidenceMarker.mark(
                for: arrival,
                biasCell: biasCells[key]
            )
        }
    }

    static func busMarks(
        predictions: [BusPrediction],
        biasCells: [BiasCellKey: BiasCell]
    ) -> [ArrivalConfidenceMark] {
        predictions.map { prediction in
            let key = BiasCellKey.make(
                line: prediction.route,
                stopId: String(prediction.stopId),
                direction: prediction.directionName,
                at: prediction.arrivalAt,
                calendar: chicagoCalendar
            )
            return ArrivalConfidenceMarker.mark(
                for: prediction,
                biasCell: biasCells[key]
            )
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

    // MARK: - Portfolio source (Phase 6)

    /// What `resolvePortfolioSource` returns: a portfolio + its
    /// approved option, with already-built train/bus legs sourced from
    /// the snapshot. `train` and `bus` can both be nil if the option's
    /// transit legs don't match any current arrivals (e.g. last train
    /// already left). Caller treats that as "no portfolio source this
    /// tick" and falls back to single-pin logic.
    ///
    /// Non-`private` so the app-target tests can inspect what
    /// `resolvePortfolioSource` produces without going through the
    /// `ensureRunning` → ActivityKit path.
    struct PortfolioSource: Sendable, Hashable {
        let portfolioID: UUID
        let optionID: UUID
        let train: CommuteAttributes.TrainLeg?
        let bus: CommuteAttributes.BusLeg?
    }

    /// Picks the first portfolio with an approved recommendation whose
    /// option has at least one resolvable transit leg, and builds the
    /// `CommuteAttributes.TrainLeg` / `BusLeg` from its first transit
    /// leg of each mode. Multi-transit-leg options (transfers) only
    /// surface their first leg of each mode — `CommuteAttributes`
    /// holds one of each, so subsequent same-mode legs can't be
    /// surfaced anyway.
    ///
    /// `nonisolated` because the body touches only its parameters; the
    /// tests need to drive it without entering the actor's executor.
    nonisolated func resolvePortfolioSource(
        prefs: UserRoutePreferences,
        recommendations: [UUID: PortfolioRecommendation],
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> PortfolioSource? {
        for portfolio in prefs.portfolios {
            guard let recommendation = recommendations[portfolio.id] else { continue }
            guard let option = portfolio.options.first(where: { $0.id == recommendation.optionID })
            else { continue }

            var train: CommuteAttributes.TrainLeg?
            var bus: CommuteAttributes.BusLeg?
            for leg in option.legs where leg.mode == .transit {
                switch leg.transit?.resolution {
                case .line where train == nil:
                    train = buildPortfolioTrainLeg(fromLeg: leg, snapshot: snapshot, biasCells: biasCells)
                case .bus where bus == nil:
                    bus = buildPortfolioBusLeg(fromLeg: leg, snapshot: snapshot, biasCells: biasCells)
                default:
                    continue
                }
            }
            guard train != nil || bus != nil else { continue }
            return PortfolioSource(
                portfolioID: portfolio.id,
                optionID: option.id,
                train: train,
                bus: bus
            )
        }
        return nil
    }

    nonisolated func buildPortfolioTrainLeg(
        fromLeg leg: RouteOptionLeg,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.TrainLeg? {
        guard case .line(let line) = leg.transit?.resolution else { return nil }
        guard let stopRef = leg.fromStopID else { return nil }
        var arrivals = snapshot.trainArrivals.filter { $0.line == line }
        switch stopRef {
        case .lStation(let id):
            arrivals = arrivals.filter { $0.stationId == id }
        case .lPlatform(let id):
            arrivals = arrivals.filter { $0.stopId == id }
        case .bus, .metra, .intercampus:
            return nil
        }
        let now = Date()
        let sorted = arrivals
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.TrainLeg(
            routeLabel: line.displayName,
            lineColorRaw: line.rawValue,
            stopName: first.stationName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: sorted.dropFirst().first?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: line, busRoute: nil)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.trainMarks(arrivals: upcoming, biasCells: biasCells)
        )
    }

    nonisolated func buildPortfolioBusLeg(
        fromLeg leg: RouteOptionLeg,
        snapshot: TransitSnapshot,
        biasCells: [BiasCellKey: BiasCell] = [:]
    ) -> CommuteAttributes.BusLeg? {
        guard case .bus(let route) = leg.transit?.resolution else { return nil }
        guard case .bus(let stopID) = leg.fromStopID else { return nil }
        let now = Date()
        let sorted = BusPredictionCalibrator
            .displayableCalibratedPredictions(
                from: snapshot.busPredictions,
                vehicles: snapshot.vehiclePositions,
                activeDetours: snapshot.busDetours,
                patterns: snapshot.busPatterns,
                stopDetourStates: snapshot.busStopDetourStates,
                bins: snapshot.busResidualBins
            )
            .filter { $0.route == route && $0.stopId == stopID && $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let upcoming = Array(sorted.prefix(6))
        return CommuteAttributes.BusLeg(
            routeLabel: "Route \(route)",
            stopName: first.stopName,
            directionLabel: first.directionName,
            destination: first.destinationName,
            nextArrival: first.arrivalAt,
            followingArrival: sorted.dropFirst().first?.arrivalAt,
            alertHeadline: snapshot.activeAlerts
                .filtered(forLine: nil, busRoute: route)
                .first?.headline,
            upcomingArrivals: upcoming.map(\.arrivalAt),
            confidenceMarks: Self.busMarks(predictions: upcoming, biasCells: biasCells)
        )
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
