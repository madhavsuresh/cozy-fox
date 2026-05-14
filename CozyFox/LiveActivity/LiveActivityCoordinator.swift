import Foundation
@preconcurrency import ActivityKit
import TransitCache
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

    func ensureRunning(snapshot: TransitSnapshot, prefs: UserRoutePreferences) async {
        guard prefs.alwaysShowLiveActivity else {
            await endCurrentIfNeeded()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let trainLeg = makeTrainLeg(prefs: prefs, snapshot: snapshot)
        let busLeg = makeBusLeg(prefs: prefs, snapshot: snapshot)
        // Metra Live Activity rendering is temporarily disabled; pinned
        // Metra still appears in the app and widgets.
        let metraLeg: CommuteAttributes.MetraLeg? = nil

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
        let metraId: String? = nil
        return (trainId, busId, metraId)
    }

    private func makeTrainLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot
    ) -> CommuteAttributes.TrainLeg? {
        // Prefer the pinned line if present; else first tracked; else nothing
        // (we don't auto-fill a "fallback" arrival when only bus is pinned).
        if let tripPin = prefs.plannedTripPin, !tripPin.trainLegs.isEmpty {
            return tripPin.trainLegs
                .compactMap { makeTripTrainLeg($0, snapshot: snapshot) }
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
        let sorted = arrivals
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
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
            upcomingArrivals: sorted.prefix(6).map(\.arrivalAt)
        )
    }

    private func makeTripTrainLeg(
        _ tripTrain: PlannedTripPin.TrainLeg,
        snapshot: TransitSnapshot
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
            upcomingArrivals: sorted.prefix(6).map(\.arrivalAt)
        )
    }

    private func makeBusLeg(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot
    ) -> CommuteAttributes.BusLeg? {
        if let tripPin = prefs.plannedTripPin, !tripPin.busLegs.isEmpty {
            return tripPin.busLegs
                .compactMap { makeTripBusLeg($0, snapshot: snapshot) }
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
        let sorted = predictions
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let first = sorted.first else { return nil }
        let following = sorted.dropFirst().first
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
            upcomingArrivals: sorted.prefix(6).map(\.arrivalAt)
        )
    }

    private func makeTripBusLeg(
        _ tripBus: PlannedTripPin.BusLeg,
        snapshot: TransitSnapshot
    ) -> CommuteAttributes.BusLeg? {
        var predictions = snapshot.busPredictions.filter { $0.route == tripBus.route }
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
            upcomingArrivals: sorted.prefix(6).map(\.arrivalAt)
        )
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
