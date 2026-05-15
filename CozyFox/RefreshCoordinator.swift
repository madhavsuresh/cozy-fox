import Foundation
import TransitAPI
import TransitCache
import TransitDomain
import TransitLocation
import TransitModels
import ActivityKit
import WidgetKit

/// The orchestrator that ties API clients, cache, and the live activity together.
/// Lives on the app side (the widget never imports this).
@MainActor
final class RefreshCoordinator {
    let store: TransitStore
    let preferences: PreferencesStore
    weak var location: LocationCoordinator?
    let walkingStore: WalkingDistanceStore
    /// Phase 2 grader. Holds its own weak ref to `ArrivalBiasStore`, so
    /// the coordinator only needs the store at construction time to wire
    /// the grader. In-memory state (the pending-grade table and the
    /// previous-snapshot map) is reset every app launch by construction.
    let arrivalGrader: ArrivalGrader

    private let trainClient: CTATrainClient
    private let busClient: CTABusClient
    private let metraClient: MetraClient
    private let intercampusClient: NorthwesternIntercampusClient
    private let alertsClient: CTAAlertsClient
    private let divvyClient: DivvyGBFSClient

    private let resolver = NearestBikeResolver()
    private let stationResolver = NearestStationResolver()
    private let busStopResolver = NearestBusStopResolver()
    private let metraStationResolver = NearestMetraStationResolver()
    private let intercampusStopResolver = NearestIntercampusStopResolver(maxDistanceMeters: 2_000)
    private let corridorResolver = TransitCorridorResolver()
    private let autopinner = CommuteAutopinner()
    /// Phase 4: detects "user just boarded a train at a CTA L station"
    /// from motion + location. Pure / stateless; the coordinator owns
    /// `previousMotion` and feeds it in.
    private let boardingDetector = BoardingDetector()

    /// Motion classification from the previous refresh cycle. Seeded as
    /// `.unknown` at launch so the first cycle never reports a
    /// transition. Updated at the end of each `applyAutopinIfNeeded()`.
    private var previousMotion: MotionContext = .unknown

    /// Day-stamp of the last walking-cache invalidation so a single 30 s
    /// foreground refresh doesn't repeatedly flush the cache. Re-invalidates
    /// once per Chicago-local calendar day so closures and construction
    /// changes get picked up.
    private var lastWalkingInvalidationDay: Date?

    /// Last-known live vehicle positions for the user's pinned line/route.
    /// Refreshed every cycle; exposed so the dashboard can draw a "where's
    /// my train" strip. Empty when no route is pinned.
    private(set) var latestPositions: [VehiclePosition] = []

    init(
        store: TransitStore,
        preferences: PreferencesStore,
        location: LocationCoordinator?,
        walkingStore: WalkingDistanceStore,
        arrivalBiasStore: ArrivalBiasStore? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.location = location
        self.walkingStore = walkingStore
        self.arrivalGrader = ArrivalGrader(biasStore: arrivalBiasStore)

        let session = LiveHTTPClient.makeSharedSession()
        let http = LiveHTTPClient(session: session)
        self.trainClient = CTATrainClient(http: http) {
            APIKeys.read(.trainTracker)
        }
        self.busClient = CTABusClient(http: http) {
            APIKeys.read(.busTracker)
        }
        self.metraClient = MetraClient(http: http) {
            APIKeys.read(.metra)
        }
        self.intercampusClient = NorthwesternIntercampusClient(http: http)
        self.alertsClient = CTAAlertsClient(http: http)
        self.divvyClient = DivvyGBFSClient(http: http)
    }

    /// Fan out the refreshes. Alerts run first so we know which stations are
    /// closed before recommending nearby trains; the rest run in parallel.
    @discardableResult
    func refreshAll() async -> Bool {
        let expiredTripChanged = clearExpiredPlannedTripPinIfNeeded()
        let autopinChanged = await applyAutopinIfNeeded()
        let prefs = preferences.loadRoutePreferences()
        let lastLocation = preferences.loadLastKnownLocation()

        invalidateWalkingCacheIfNewDay()

        // Phase 1: alerts. Needed before train recommendations so we can
        // exclude stations the alerts flag as closed (e.g. State/Lake).
        await refreshAlerts(prefs: prefs)
        let alertsSnapshot = await store.currentSnapshot()
        let closedStations = ClosedStationsAnalyzer.closedStationIds(
            from: alertsSnapshot.activeAlerts
        )

        // Phase 2: parallel data fetches.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.refreshTrains(
                    prefs: prefs,
                    lastLocation: lastLocation,
                    closedStations: closedStations
                )
            }
            group.addTask { await self.refreshBuses(prefs: prefs, lastLocation: lastLocation) }
            group.addTask { await self.refreshMetra(prefs: prefs, lastLocation: lastLocation) }
            group.addTask { await self.refreshIntercampus(prefs: prefs, lastLocation: lastLocation) }
            group.addTask {
                if prefs.isModeVisible(.bikes) {
                    await self.refreshBikes(
                        origin: lastLocation,
                        includeFreeFloating: prefs.includeFreeFloatingBikes
                    )
                } else {
                    await self.store.replaceNearbyBikePicks([])
                }
            }
            group.addTask { await self.refreshPositions(prefs: prefs) }
        }

        // Keep the always-on Live Activity (if enabled) in sync with the
        // freshly-refreshed snapshot.
        let snapshot = await store.currentSnapshot()
        await LiveActivityCoordinator.shared.ensureRunning(snapshot: snapshot, prefs: prefs)

        WidgetCenter.shared.reloadAllTimelines()
        return expiredTripChanged || autopinChanged
    }

    /// Called whenever the location coordinator detects a region transition.
    func handleContextChange(_ context: CommuteContext) async {
        await refreshAll()
    }

    /// Called on region exit (leaving home/work) — auto-start a Live Activity
    /// for the relevant direction if the user has it enabled.
    func handleRegionExit(direction: CommuteDirection) async {
        let prefs = preferences.loadRoutePreferences()
        guard prefs.autoStartLiveActivity else { return }
        guard let pref = prefs.trains.first(where: {
            $0.direction == direction && prefs.isTrainLineVisible($0.line)
        })
            ?? prefs.buses.first(where: {
                $0.direction == direction && prefs.isBusRouteVisible($0.route)
            }).map(toTrainStub) else {
            return
        }
        await refreshAll()
        await LiveActivityCoordinator.shared.startCommute(
            for: pref,
            snapshot: await store.currentSnapshot()
        )
    }

    private func toTrainStub(_ bus: BusPreference) -> TrainPreference {
        // Only used when no train preference exists — Live Activity surfaces
        // the bus arrival via this stub.
        TrainPreference(
            mapId: 0,
            stopId: bus.stopId,
            stationName: bus.stopName,
            line: .red,
            directionLabel: bus.directionLabel,
            direction: bus.direction
        )
    }

    private func applyAutopinIfNeeded() async -> Bool {
        if preferences.loadRoutePreferences().plannedTripPin != nil {
            return false
        }
        let motion = await location?.refreshMotion() ?? .unknown
        // Phase 4: check whether the user just boarded a train at a CTA
        // L station. Uses the *cached* `lastKnown` location instead of
        // a one-shot `refreshLocation()` to keep this cheap — stale by
        // up to a few minutes is acceptable here, the 150m radius
        // tolerates drift, and false negatives at the boundary are
        // preferable to extra battery.
        if let boarding = boardingDetector.detect(
            previousMotion: previousMotion,
            currentMotion: motion,
            currentLocation: location?.lastKnown
        ) {
            await arrivalGrader.ingestBoardingEvent(
                stationId: boarding.stationId,
                observedAt: boarding.observedAt
            )
        }
        previousMotion = motion

        let context = location?.context ?? .unknown
        let result = autopinner.apply(
            preferences: preferences.loadRoutePreferences(),
            anchors: preferences.loadCommuteAnchors(),
            profile: preferences.loadMobilityProfile(),
            location: preferences.loadLastKnownLocation(),
            context: context,
            motion: motion
        )
        if result.changed {
            preferences.saveRoutePreferences(result.preferences)
        }
        return result.changed
    }

    private func clearExpiredPlannedTripPinIfNeeded() -> Bool {
        var prefs = preferences.loadRoutePreferences()
        guard prefs.clearExpiredPlannedTripPin() else { return false }
        preferences.saveRoutePreferences(prefs)
        return true
    }

    // MARK: - Per-service refreshers

    private func refreshTrains(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?,
        closedStations: Set<Int>
    ) async {
        // Build the set of (mapId, stopId?) targets to query the Train Tracker
        // for: tracked stations OR the nearest few + the pinned-line station.
        var targets: [(mapId: Int, stopId: Int?)] = []

        let visibleTrainPrefs = prefs.trains.filter {
            prefs.isTrainLineVisible($0.line) || prefs.pinnedLine == $0.line
        }
        if !visibleTrainPrefs.isEmpty {
            // Honor tracked stations even if the alerts feed says they're
            // closed — the user picked them on purpose, surface the staleness.
            targets.append(contentsOf: visibleTrainPrefs.map { ($0.mapId, $0.stopId) })
        }
        if prefs.isModeVisible(.trains), let lastLocation {
            let nearest = corridorResolver.nearbyTrainCandidates(
                to: (lastLocation.latitude, lastLocation.longitude),
                radiusMeters: 2_000,
                limitPerCorridor: 1,
                catalog: LStationCatalog.all.filter { station in
                    station.servedLines.contains(where: prefs.isTrainLineVisible)
                },
                excludingStationIds: closedStations
            )
            for candidate in nearest {
                guard !targets.contains(where: {
                    $0.mapId == candidate.station.id && $0.stopId == nil
                }) else { continue }
                targets.append((candidate.station.id, nil))
            }
        }

        for tripTrain in prefs.plannedTripPin?.trainLegs ?? [] {
            guard let stationId = tripTrain.stationId else { continue }
            if !targets.contains(where: { $0.mapId == stationId }) {
                targets.append((stationId, nil))
            }
        }

        // Pinned line: include the user's chosen station (or the nearest
        // station on that line as a fallback), skipping closed stations
        // unless the user explicitly pinned one.
        if let pinned = prefs.pinnedLine, let lastLocation {
            let stationId: Int? = {
                if let explicit = prefs.pinnedStationId,
                   LStationCatalog.all.contains(where: {
                       $0.id == explicit && $0.servedLines.contains(pinned)
                   })
                {
                    return explicit
                }
                return stationResolver.closestStations(
                    onLine: pinned,
                    to: (lastLocation.latitude, lastLocation.longitude),
                    limit: 1,
                    catalog: LStationCatalog.all,
                    excludingStationIds: closedStations
                ).first?.station.id
            }()
            if let stationId,
               !targets.contains(where: { $0.mapId == stationId })
            {
                targets.append((stationId, nil))
            }
        }

        var collected: [Arrival] = []
        for target in targets {
            do {
                let result: [Arrival]
                if let stopId = target.stopId {
                    // stopId queries return one platform's arrivals (one
                    // direction) — 4 is plenty.
                    result = try await trainClient.fetchArrivals(stopId: stopId, max: 4)
                } else {
                    // mapId queries return every line at that station in both
                    // directions sorted by time — needs enough headroom that
                    // each (line × direction) pair gets a couple of arrivals.
                    // At Belmont's 3 lines × 2 directions = 6 pairs, 12 keeps
                    // both directions visible.
                    result = try await trainClient.fetchArrivals(mapId: target.mapId, max: 12)
                }
                collected.append(contentsOf: result)
            } catch {
                // Skip on transient failure; existing cache stays.
                continue
            }
        }

        if !collected.isEmpty {
            await store.replaceTrainArrivals(collected)
        }
        // Phase 2: hand the freshly-fetched arrivals to the grader so it can
        // register pending grades. Always runs (even on empty `collected`)
        // so callers see consistent behavior; the grader's own guard short-
        // circuits the empty case.
        await arrivalGrader.ingestArrivals(collected)
    }

    private func refreshBuses(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?
    ) async {
        var targets: [(route: String, stopId: Int)] = []

        let visibleBusPrefs = prefs.buses.filter {
            prefs.isBusRouteVisible($0.route) || prefs.pinnedBusRoute == $0.route
        }
        if !visibleBusPrefs.isEmpty {
            targets.append(contentsOf: visibleBusPrefs.map { ($0.route, $0.stopId) })
        }
        if prefs.isModeVisible(.buses), let lastLocation {
            // Surface predictions for nearby directional coverage (N/S, E/W,
            // diagonal), not just the closest few routes.
            let nearest = corridorResolver.nearbyBusCandidates(
                to: (lastLocation.latitude, lastLocation.longitude),
                radiusMeters: 1_500,
                limitPerCorridor: 2,
                catalog: BusStopCatalog.all.filter { prefs.isBusRouteVisible($0.route) }
            )
            for candidate in nearest {
                guard !targets.contains(where: {
                    $0.route == candidate.stop.route && $0.stopId == candidate.stop.id
                }) else { continue }
                targets.append((candidate.stop.route, candidate.stop.id))
            }
        }

        // Pinned bus route: fetch the nearest stops in EACH direction so the
        // dashboard can show both adjacent stop choices for a rider standing
        // between stops.
        if let pinnedRoute = prefs.pinnedBusRoute, let lastLocation {
            if let pinnedStopId = prefs.pinnedBusStopId,
               let explicitStop = BusStopCatalog.all.first(where: {
                   $0.route == pinnedRoute
                       && $0.id == pinnedStopId
                       && (prefs.pinnedBusDirection == nil
                           || $0.directionLabel == prefs.pinnedBusDirection)
               }),
               !targets.contains(where: { $0.route == pinnedRoute && $0.stopId == explicitStop.id })
            {
                targets.append((pinnedRoute, explicitStop.id))
            }

            let directionalStops = busStopResolver.nearestStopsPerDirection(
                onRoute: pinnedRoute,
                to: (lastLocation.latitude, lastLocation.longitude),
                limitPerDirection: 2,
                catalog: BusStopCatalog.all
            )
            for stop in directionalStops where !targets.contains(where: {
                $0.route == pinnedRoute && $0.stopId == stop.stop.id
            }) {
                targets.append((pinnedRoute, stop.stop.id))
            }
        }

        for tripBus in prefs.plannedTripPin?.busLegs ?? [] {
            guard let stopId = tripBus.stopId else { continue }
            if !targets.contains(where: { $0.route == tripBus.route && $0.stopId == stopId }) {
                targets.append((tripBus.route, stopId))
            }
        }

        var collected: [BusPrediction] = []
        for target in targets {
            do {
                let result = try await busClient.fetchPredictions(
                    route: target.route, stopId: target.stopId, top: 4
                )
                collected.append(contentsOf: result)
            } catch {
                continue
            }
        }

        if !collected.isEmpty {
            await store.replaceBusPredictions(collected)
        }
    }

    private func refreshMetra(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?
    ) async {
        var targets: [(routeId: String, stationId: String, directionId: Int?)] = []

        let visibleMetraPrefs = prefs.metra.filter {
            prefs.isMetraRouteVisible($0.routeId) || prefs.pinnedMetraRoute == $0.routeId
        }
        if !visibleMetraPrefs.isEmpty {
            targets.append(contentsOf: visibleMetraPrefs.map {
                ($0.routeId, $0.stationId, $0.directionId)
            })
        } else if prefs.isModeVisible(.metra), let lastLocation {
            let nearest = metraStationResolver.nearestPerRoute(
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 5,
                catalog: MetraStationCatalog.all.filter { station in
                    station.servedRoutes.contains(where: prefs.isMetraRouteVisible)
                }
            )
            targets.append(contentsOf: nearest.map { ($0.routeId, $0.station.id, nil) })
        }

        for tripMetra in prefs.plannedTripPin?.metraLegs ?? [] {
            guard let stationId = tripMetra.stationId else { continue }
            if !targets.contains(where: { $0.routeId == tripMetra.routeId && $0.stationId == stationId }) {
                targets.append((tripMetra.routeId, stationId, tripMetra.directionId))
            }
        }

        if let pinnedRoute = prefs.pinnedMetraRoute, let lastLocation {
            if let pinnedStationId = prefs.pinnedMetraStationId,
               MetraStationCatalog.all.contains(where: {
                   $0.id == pinnedStationId && $0.servedRoutes.contains(pinnedRoute)
               }),
               !targets.contains(where: { $0.routeId == pinnedRoute && $0.stationId == pinnedStationId })
            {
                targets.append((pinnedRoute, pinnedStationId, prefs.pinnedMetraDirectionId))
            }

            let nearest = metraStationResolver.closestStations(
                onRoute: pinnedRoute,
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 3,
                catalog: MetraStationCatalog.all
            )
            for station in nearest where !targets.contains(where: {
                $0.routeId == pinnedRoute && $0.stationId == station.station.id
            }) {
                targets.append((pinnedRoute, station.station.id, prefs.pinnedMetraDirectionId))
            }
        }

        guard !targets.isEmpty else { return }

        let updates = (try? await metraClient.fetchTripUpdates()) ?? []
        let updateByTripStop = Dictionary(grouping: updates) { update in
            "\(update.tripId)|\(update.stopId)"
        }

        var collected: [MetraPrediction] = []
        for target in targets {
            let scheduled = MetraScheduleCatalog.upcomingDepartures(
                stationId: target.stationId,
                routeId: target.routeId,
                directionId: target.directionId,
                now: .now,
                limit: 4
            )
            collected.append(contentsOf: scheduled.map { prediction in
                let key = "\(prediction.tripId)|\(prediction.stationId)"
                guard let latest = updateByTripStop[key]?.max(by: { $0.generatedAt < $1.generatedAt }) else {
                    return prediction
                }
                return prediction.applying(latest)
            })
        }

        var seen: Set<String> = []
        let unique = collected
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .filter { seen.insert($0.id).inserted }
        if !unique.isEmpty {
            await store.replaceMetraPredictions(unique)
        }
    }

    private func refreshIntercampus(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?
    ) async {
        guard prefs.includeIntercampus,
              prefs.isModeVisible(.intercampus) || prefs.pinnedIntercampusStopId != nil
        else {
            await store.replaceIntercampusArrivals([])
            return
        }
        guard let lastLocation else {
            await store.replaceIntercampusArrivals([])
            return
        }

        let origin = (lastLocation.latitude, lastLocation.longitude)
        let nearby = intercampusStopResolver.nearestPerDirection(
            to: origin,
            limitPerDirection: 12,
            catalog: IntercampusCatalog.all
        )
        var targetStopIds = Set(nearby.map(\.stop.id))
        if let selectedStopId = prefs.pinnedIntercampusStopId,
           IntercampusCatalog.stop(id: selectedStopId) != nil
        {
            targetStopIds.insert(selectedStopId)
        }
        guard !targetStopIds.isEmpty else {
            await store.replaceIntercampusArrivals([])
            return
        }

        do {
            let arrivals = try await intercampusClient.fetchArrivals(
                stopIds: targetStopIds,
                now: .now
            )
            var perStopDirectionCounts: [String: Int] = [:]
            let capped = arrivals
                .sorted { $0.arrivalAt < $1.arrivalAt }
                .filter { arrival in
                    let key = "\(arrival.direction.rawValue)-\(arrival.stopId)"
                    let count = perStopDirectionCounts[key] ?? 0
                    guard count < 4 else { return false }
                    perStopDirectionCounts[key] = count + 1
                    return true
                }
            await store.replaceIntercampusArrivals(capped)
        } catch {
            // Leave the previous cache in place on transient TripShot failures.
        }
    }


    /// Fetches live vehicle positions for whichever line + bus route the user
    /// has pinned, so the dashboard's "where's my train/bus" strip can show
    /// where the next vehicle actually is on the ground. Only fires when a
    /// pin is active to avoid burning rate-limit budget on unused data.
    private func refreshPositions(prefs: UserRoutePreferences) async {
        var collected: [VehiclePosition] = []
        var trainLines = Set(prefs.plannedTripPin?.trainLegs.map(\.line) ?? [])
        if let line = prefs.pinnedLine { trainLines.insert(line) }
        if !trainLines.isEmpty {
            if let trains = try? await trainClient.fetchPositions(lines: Array(trainLines)) {
                collected.append(contentsOf: trains)
            }
        }
        var busRoutes = Set(prefs.plannedTripPin?.busLegs.map(\.route) ?? [])
        if let route = prefs.pinnedBusRoute { busRoutes.insert(route) }
        if !busRoutes.isEmpty {
            if let buses = try? await busClient.fetchVehicles(routes: Array(busRoutes)) {
                collected.append(contentsOf: buses)
            }
        }
        var metraRoutes = Set(prefs.plannedTripPin?.metraLegs.map(\.routeId) ?? [])
        if let route = prefs.pinnedMetraRoute { metraRoutes.insert(route) }
        if !metraRoutes.isEmpty {
            if let trains = try? await metraClient.fetchPositions(routes: Array(metraRoutes)) {
                collected.append(contentsOf: trains)
            }
        }
        latestPositions = collected
        // Phase 2: feed the snapshot to the grader so it can resolve any
        // pending grades against this snapshot's `nextStopId` transitions
        // before the store overwrite. Either order is correct (the grader
        // owns its own state) but doing it before `replaceVehiclePositions`
        // keeps the pre/post-store-write boundary readable.
        await arrivalGrader.ingestPositions(collected)
        await store.replaceVehiclePositions(collected)
    }

    private func refreshAlerts(prefs: UserRoutePreferences) async {
        var routes: Set<String> = []
        let visibleTrackedLines = prefs.trains
            .filter { prefs.isTrainLineVisible($0.line) || prefs.pinnedLine == $0.line }
            .map { $0.line.rawValue.capitalized }
        let visibleTrackedBuses = prefs.buses
            .filter { prefs.isBusRouteVisible($0.route) || prefs.pinnedBusRoute == $0.route }
            .map(\.route)
        let visibleTrackedMetra = prefs.metra
            .filter { prefs.isMetraRouteVisible($0.routeId) || prefs.pinnedMetraRoute == $0.routeId }
            .map(\.routeId)

        routes.formUnion(visibleTrackedLines)
        routes.formUnion(visibleTrackedBuses)
        routes.formUnion(visibleTrackedMetra)
        if let pinnedLine = prefs.pinnedLine {
            routes.insert(pinnedLine.rawValue.capitalized)
        }
        if let pinnedBusRoute = prefs.pinnedBusRoute {
            routes.insert(pinnedBusRoute)
        }
        if let pinnedMetraRoute = prefs.pinnedMetraRoute {
            routes.insert(pinnedMetraRoute)
        }
        routes.formUnion(prefs.plannedTripPin?.trainLegs.map { $0.line.rawValue.capitalized } ?? [])
        routes.formUnion(prefs.plannedTripPin?.busLegs.map(\.route) ?? [])
        routes.formUnion(prefs.plannedTripPin?.metraLegs.map(\.routeId) ?? [])

        async let metraAlerts = (try? metraClient.fetchAlerts()) ?? []
        do {
            let alerts = try await alertsClient.fetchActiveAlerts(forRoutes: Array(routes))
            await store.replaceAlerts(alerts + (await metraAlerts))
        } catch {
            await store.replaceAlerts(await metraAlerts)
        }
    }

    private func refreshBikes(
        origin: LastKnownLocation?,
        includeFreeFloating: Bool
    ) async {
        do {
            async let stationsTask = divvyClient.fetchStations()
            async let bikesTask = divvyClient.fetchEBikes()
            let (stations, ebikes) = try await (stationsTask, bikesTask)
            await store.recordStationSnapshots(stations)

            guard let origin else {
                await store.replaceNearbyBikePicks([])
                return
            }
            let picks = resolver.nearby(
                topStations: 3,
                topFreeFloating: 3,
                from: (origin.latitude, origin.longitude),
                stations: stations,
                eBikes: ebikes,
                includeFreeFloating: includeFreeFloating
            )
            await store.replaceNearbyBikePicks(
                picks.stationPicks,
                freeFloatingPicks: picks.freeFloatingPicks
            )
        } catch {
            // leave previous nearest bike in place
        }
    }

    /// Marks every access-route cache entry stale once per Chicago-local
    /// day. The stale data is still readable as a fallback, but the
    /// stop chips' `ensureFresh` calls will see a miss and re-query MapKit,
    /// which picks up bridge closures, construction reroutes, and any updates
    /// Apple Maps has ingested since the last fetch.
    private func invalidateWalkingCacheIfNewDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let today = cal.startOfDay(for: Date())
        if let last = lastWalkingInvalidationDay, cal.isDate(last, inSameDayAs: today) {
            return
        }
        lastWalkingInvalidationDay = today
        walkingStore.invalidateAll()
    }
}
