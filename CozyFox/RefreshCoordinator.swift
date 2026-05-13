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

    private let trainClient: CTATrainClient
    private let busClient: CTABusClient
    private let alertsClient: CTAAlertsClient
    private let divvyClient: DivvyGBFSClient

    private let resolver = NearestBikeResolver()
    private let stationResolver = NearestStationResolver()
    private let busStopResolver = NearestBusStopResolver()
    private let autopinner = CommuteAutopinner()

    /// Last-known live vehicle positions for the user's pinned line/route.
    /// Refreshed every cycle; exposed so the dashboard can draw a "where's
    /// my train" strip. Empty when no route is pinned.
    private(set) var latestPositions: [VehiclePosition] = []

    init(
        store: TransitStore,
        preferences: PreferencesStore,
        location: LocationCoordinator?
    ) {
        self.store = store
        self.preferences = preferences
        self.location = location

        let session = LiveHTTPClient.makeSharedSession()
        let http = LiveHTTPClient(session: session)
        self.trainClient = CTATrainClient(http: http) {
            APIKeys.read(.trainTracker)
        }
        self.busClient = CTABusClient(http: http) {
            APIKeys.read(.busTracker)
        }
        self.alertsClient = CTAAlertsClient(http: http)
        self.divvyClient = DivvyGBFSClient(http: http)
    }

    /// Fan out the refreshes. Alerts run first so we know which stations are
    /// closed before recommending nearby trains; the rest run in parallel.
    @discardableResult
    func refreshAll() async -> Bool {
        let autopinChanged = applyAutopinIfNeeded()
        let prefs = preferences.loadRoutePreferences()
        let lastLocation = preferences.loadLastKnownLocation()

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
            group.addTask {
                await self.refreshBikes(
                    origin: lastLocation,
                    includeFreeFloating: prefs.includeFreeFloatingBikes
                )
            }
            group.addTask { await self.refreshPositions(prefs: prefs) }
        }

        // Keep the always-on Live Activity (if enabled) in sync with the
        // freshly-refreshed snapshot.
        let snapshot = await store.currentSnapshot()
        await LiveActivityCoordinator.shared.ensureRunning(snapshot: snapshot, prefs: prefs)

        WidgetCenter.shared.reloadAllTimelines()
        return autopinChanged
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
        guard let pref = prefs.trains.first(where: { $0.direction == direction })
            ?? prefs.buses.first(where: { $0.direction == direction }).map(toTrainStub) else {
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

    private func applyAutopinIfNeeded() -> Bool {
        let result = autopinner.apply(
            preferences: preferences.loadRoutePreferences(),
            anchors: preferences.loadCommuteAnchors(),
            profile: preferences.loadMobilityProfile(),
            location: preferences.loadLastKnownLocation(),
            context: location?.context ?? .unknown
        )
        if result.changed {
            preferences.saveRoutePreferences(result.preferences)
        }
        return result.changed
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

        if !prefs.trains.isEmpty {
            // Honor tracked stations even if the alerts feed says they're
            // closed — the user picked them on purpose, surface the staleness.
            targets.append(contentsOf: prefs.trains.map { ($0.mapId, $0.stopId) })
        } else if let lastLocation {
            let nearest = stationResolver.nearest(
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 3,
                catalog: LStationCatalog.all,
                excludingStationIds: closedStations
            )
            targets.append(contentsOf: nearest.map { ($0.id, nil) })
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
    }

    private func refreshBuses(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?
    ) async {
        var targets: [(route: String, stopId: Int)] = []

        if !prefs.buses.isEmpty {
            targets.append(contentsOf: prefs.buses.map { ($0.route, $0.stopId) })
        } else if let lastLocation {
            // No tracked buses — surface predictions for the nearest 5
            // distinct routes from the bundled CTA bus stop catalog.
            let nearest = busStopResolver.nearest(
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 5,
                catalog: BusStopCatalog.all
            )
            targets.append(contentsOf: nearest.map { ($0.route, $0.id) })
        }

        // Pinned bus route: fetch the nearest stop in EACH direction so the
        // dashboard can show both legs (e.g., #22 northbound + southbound).
        if let pinnedRoute = prefs.pinnedBusRoute, let lastLocation {
            let directionalStops = busStopResolver.nearestPerDirection(
                onRoute: pinnedRoute,
                to: (lastLocation.latitude, lastLocation.longitude),
                catalog: BusStopCatalog.all
            )
            for stop in directionalStops where !targets.contains(where: {
                $0.route == pinnedRoute && $0.stopId == stop.id
            }) {
                targets.append((pinnedRoute, stop.id))
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


    /// Fetches live vehicle positions for whichever line + bus route the user
    /// has pinned, so the dashboard's "where's my train/bus" strip can show
    /// where the next vehicle actually is on the ground. Only fires when a
    /// pin is active to avoid burning rate-limit budget on unused data.
    private func refreshPositions(prefs: UserRoutePreferences) async {
        var collected: [VehiclePosition] = []
        if let line = prefs.pinnedLine {
            if let trains = try? await trainClient.fetchPositions(lines: [line]) {
                collected.append(contentsOf: trains)
            }
        }
        if let route = prefs.pinnedBusRoute {
            if let buses = try? await busClient.fetchVehicles(routes: [route]) {
                collected.append(contentsOf: buses)
            }
        }
        latestPositions = collected
    }

    private func refreshAlerts(prefs: UserRoutePreferences) async {
        let routes = Set(
            prefs.trains.map { $0.line.rawValue.capitalized }
            + prefs.buses.map { $0.route }
        )
        do {
            let alerts = try await alertsClient.fetchActiveAlerts(forRoutes: Array(routes))
            await store.replaceAlerts(alerts)
        } catch {
            // ignore — Alerts API is best-effort
        }
    }

    private func refreshBikes(
        origin: LastKnownLocation?,
        includeFreeFloating: Bool
    ) async {
        do {
            async let stationsTask = divvyClient.fetchStations()
            async let bikesTask = includeFreeFloating ? divvyClient.fetchEBikes() : []
            let (stations, ebikes) = try await (stationsTask, bikesTask)
            await store.recordStationSnapshots(stations)

            guard let origin else {
                await store.replaceNearbyBikePicks([])
                return
            }
            let picks = resolver.picks(
                top: 3,
                from: (origin.latitude, origin.longitude),
                stations: stations,
                eBikes: ebikes,
                includeFreeFloating: includeFreeFloating
            )
            await store.replaceNearbyBikePicks(picks)
        } catch {
            // leave previous nearest bike in place
        }
    }
}
