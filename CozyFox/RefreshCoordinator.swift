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
    /// Phase 5: stopwatch that pairs region-exit timestamps with Phase 4
    /// boarding events to feed a per-user MapKit walk-speed correction.
    let walkSpeedTracker: WalkSpeedTracker
    /// Phase 5b: motion-transition stopwatch for cycling. Independent of
    /// walking because pace ratios don't transfer between modes.
    let bikeSpeedTracker: BikeSpeedTracker
    /// Stitches region exits with boardings / anchor entries to feed
    /// `MobilityProfile.commuteLegObservations`, which
    /// `PersonalAccessEstimator` reads for per-route access-time
    /// learning.
    let commuteLegTracker: CommuteLegTracker

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
    private let intercampusTrafficResolver = IntercampusTrafficETAResolver()
    private let corridorResolver = TransitCorridorResolver()
    private let autopinner = CommuteAutopinner()
    /// Phase 4: detects "user just boarded a train at a CTA L station"
    /// from motion + location. Pure / stateless; the coordinator owns
    /// `previousMotion` and feeds it in.
    private let boardingDetector = BoardingDetector()
    /// Phase 6 consumer: when `NextContextPredictor` is confident the
    /// user is about to head to a known anchor, this asks for a plan to
    /// warm the MapKit walking cache for nearby stations.
    private let predictivePrefetcher = PredictiveStationPrefetcher()
    /// Thin convenience over `walkingStore` so the predictor's plan can
    /// trigger MapKit prefetches without re-implementing the resolver's
    /// inflight / negative-cache bookkeeping.
    private let walkingResolver: WalkingDistanceResolver

    /// Motion classification from the previous refresh cycle. Seeded as
    /// `.unknown` at launch so the first cycle never reports a
    /// transition. Updated at the end of each `applyAutopinIfNeeded()`.
    private var previousMotion: MotionContext = .unknown

    /// Day-stamp of the last walking-cache invalidation so a single 30 s
    /// foreground refresh doesn't repeatedly flush the cache. Re-invalidates
    /// once per Chicago-local calendar day so closures and construction
    /// changes get picked up.
    private var lastWalkingInvalidationDay: Date?

    /// Last successful detour fetch. Throttles `refreshDetoursIfNeeded` so
    /// we don't hit `getdetours` on every 30 s refresh cycle — detours
    /// change on the order of hours, not seconds.
    private var lastDetoursFetchedAt: Date?
    private static let detourRefreshInterval: TimeInterval = 5 * 60

    /// Last successful pattern fetch and the route set that fetch covered.
    /// Patterns change very rarely (on detour-version changes), so an
    /// hourly cadence is plenty — and the set of pinned routes also rarely
    /// changes, so we only re-fetch when *either* the hour passes or the
    /// route set grows.
    private var lastPatternsFetchedAt: Date?
    private var lastPatternsRouteSet: Set<String> = []
    private static let patternRefreshInterval: TimeInterval = 60 * 60

    /// Last-known live vehicle positions for the user's pinned line/route.
    /// Refreshed every cycle; exposed so the dashboard can draw a "where's
    /// my train" strip. Empty when no route is pinned.
    private(set) var latestPositions: [VehiclePosition] = []

    /// Latest Divvy GBFS station + free-bike snapshot, held in memory only.
    /// The dashboard's trip-pin Divvy chips read directly from this — the
    /// full station list never goes through SwiftData. Empty until the
    /// first successful `refreshBikes`.
    private(set) var latestBikeInventory: BikeInventorySnapshot = .empty

    /// Phase 5b Tier 2: opt-in GPS sampler for cycling sessions.
    /// Subscribes to CLLocation only while motion is `.cycling` AND
    /// the user has the setting on AND iOS isn't in Low Power Mode.
    let bikeRouteSampler: BikeRouteSampler

    // MARK: - Portfolio evaluation (Phase 4)

    /// Strong reference to the bias store so the portfolio evaluator's
    /// `BiasCorrectionReader` can be re-snapshotted each tick. Optional
    /// because tests can stand the coordinator up without one.
    private let biasStore: ArrivalBiasStore?
    private let portfolioEvaluator: PortfolioEvaluator
    private let portfolioMissCostCalculator: MissCostCalculator
    private let portfolioHysteresis = PortfolioHysteresis()
    /// Per-portfolio hysteresis state, keyed by `RoutePortfolio.id`.
    /// Survives across refresh ticks; cleared when the user removes a
    /// portfolio.
    private var portfolioHysteresisState: [UUID: PortfolioHysteresis.State] = [:]
    /// Latest per-tick evaluation results, exposed for `AppViewModel`
    /// to mirror into its observable surface.
    private(set) var latestPortfolioEvaluations: [UUID: PortfolioEvaluation] = [:]
    /// Latest hysteresis-approved recommendation per portfolio. May
    /// differ from `latestPortfolioEvaluations[id].recommendedOptionID`
    /// when the candidate hasn't beaten the current pick for long
    /// enough.
    private(set) var latestPortfolioRecommendations: [UUID: PortfolioRecommendation] = [:]
    /// Bumped each refresh tick that changed a recommendation (or that
    /// produced new evaluations after a portfolio was added). Mirrored
    /// onto `AppViewModel.portfolioRevision` so SwiftUI consumers can
    /// `.onChange(of:)` for selective invalidation.
    private(set) var portfolioRevision: Int = 0

    init(
        store: TransitStore,
        preferences: PreferencesStore,
        location: LocationCoordinator?,
        walkingStore: WalkingDistanceStore,
        arrivalBiasStore: ArrivalBiasStore? = nil,
        bikeRouteStore: BikeRouteStore? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.location = location
        self.walkingStore = walkingStore
        self.walkingResolver = WalkingDistanceResolver(store: walkingStore)
        self.arrivalGrader = ArrivalGrader(
            biasStore: arrivalBiasStore,
            residualRecorder: { [weak store] residual in
                guard let store else { return }
                Task { await store.recordBusResidual(residual) }
            }
        )
        self.walkSpeedTracker = WalkSpeedTracker(walkingStore: walkingStore)
        self.bikeSpeedTracker = BikeSpeedTracker(walkingStore: walkingStore)
        self.commuteLegTracker = CommuteLegTracker(preferences: preferences)
        self.bikeRouteSampler = BikeRouteSampler(routeStore: bikeRouteStore)

        // Portfolio evaluator + miss-cost share one scorer so their
        // bias / weight assumptions stay consistent.
        let portfolioScorer = RouteOptionScorer()
        self.biasStore = arrivalBiasStore
        self.portfolioEvaluator = PortfolioEvaluator(scorer: portfolioScorer)
        self.portfolioMissCostCalculator = MissCostCalculator(scorer: portfolioScorer)

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

        // Phase 6 consumer: kick off MapKit prefetch for stations near
        // the predicted next destination anchor. Runs in parallel with
        // the Phase 2 fetches below — the predictor lookup is cheap
        // (in-memory histogram build) and the resolver's own inflight
        // dedup keeps us from re-querying anything that's already
        // warming.
        primePredictedDestinationWalking()

        // Track when the user first transitioned into `.elsewhere` so
        // the head-home tile can reason about outing duration even
        // across app launches. Cleared when context returns to a
        // known anchor.
        updateElsewhereTracking()

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
            group.addTask { await self.refreshDetoursIfNeeded(prefs: prefs) }
            group.addTask { await self.refreshPatternsIfNeeded(prefs: prefs) }
        }

        // Phase 4: portfolio evaluation. Runs after the parallel
        // fetches so the snapshot includes freshly-refreshed arrivals;
        // before the Live Activity hand-off so future phases can let
        // the coordinator pick a portfolio recommendation as the LA's
        // source of truth.
        let snapshot = await store.currentSnapshot()
        evaluatePortfolios(
            prefs: prefs,
            transitSnapshot: snapshot,
            closedStations: closedStations
        )

        // Keep the always-on Live Activity (if enabled) in sync with the
        // freshly-refreshed snapshot. Pass the per-portfolio
        // recommendations so the LA picks a portfolio's approved
        // option as its source of truth when one exists, falling back
        // to the single-pin / planned-trip-pin path otherwise. Also
        // snapshot the bias cells so the LA can vary dot weight /
        // opacity per-arrival via `ArrivalConfidenceMarker`.
        let biasCellsSnapshot = biasStore?.cells ?? [:]
        await LiveActivityCoordinator.shared.ensureRunning(
            snapshot: snapshot,
            prefs: prefs,
            portfolioRecommendations: latestPortfolioRecommendations,
            biasCells: biasCellsSnapshot
        )

        WidgetCenter.shared.reloadAllTimelines()
        return expiredTripChanged || autopinChanged
    }

    /// Called whenever the location coordinator detects a region transition.
    func handleContextChange(_ context: CommuteContext) async {
        commuteLegTracker.recordAnchorEntry(
            context: context,
            at: .now,
            routePreferences: preferences.loadRoutePreferences()
        )
        await refreshAll()
    }

    /// Called on region exit (leaving home/work) — auto-start a Live Activity
    /// for the relevant direction if the user has it enabled. Also marks
    /// the Phase 5 walk-speed tracker so a later boarding event can be
    /// timed against this exit.
    func handleRegionExit(direction: CommuteDirection) async {
        let anchors = preferences.loadCommuteAnchors()
        let anchor: CommuteAnchors.Anchor? = {
            switch direction {
            case .toWork: return anchors.home
            case .toHome: return anchors.work
            case .anytime: return nil
            }
        }()
        if let anchor {
            walkSpeedTracker.recordRegionExit(direction: direction, anchor: anchor, at: .now)
        }
        commuteLegTracker.recordRegionExit(direction: direction, at: .now)
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
        // Single load — `loadRoutePreferences` does a UserDefaults read +
        // JSON decode. The function previously called it twice per
        // refresh; reuse the same snapshot for the planned-trip gate and
        // the autopin call.
        let prefsSnapshot = preferences.loadRoutePreferences()
        if prefsSnapshot.plannedTripPin != nil {
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
            // Phase 5: this boarding moment also closes out any pending
            // walk segment started by a prior region exit, feeding the
            // per-user walk-speed correction.
            walkSpeedTracker.recordBoarding(
                stationId: boarding.stationId,
                at: boarding.observedAt
            )
            // Pair with `CommuteLegTracker`'s pending region-exit so a
            // `CommuteLegObservation` lands on the profile —
            // `PersonalAccessEstimator` reads these for per-route
            // access-time learning.
            commuteLegTracker.recordBoarding(
                stationId: boarding.stationId,
                observedAt: boarding.observedAt,
                routePreferences: preferences.loadRoutePreferences()
            )
        }

        // Phase 5b: motion-transition pairs for cycling. We pick up the
        // start at the moment motion enters .cycling and close out when
        // it leaves. Uses cached `lastKnown` for the endpoints — radius
        // resolution to a known anchor / station forgives staleness.
        let cyclingStarted = previousMotion != .cycling && motion == .cycling
        let cyclingEnded = previousMotion == .cycling && motion != .cycling
        if cyclingStarted, let loc = location?.lastKnown {
            bikeSpeedTracker.recordRideStart(
                at: (lat: loc.latitude, lon: loc.longitude),
                at: .now,
                anchors: preferences.loadCommuteAnchors()
            )
        } else if cyclingEnded, let loc = location?.lastKnown {
            bikeSpeedTracker.recordRideEnd(
                at: (lat: loc.latitude, lon: loc.longitude),
                at: .now
            )
        }

        // Tier 2 (GPS route sampling) — gated on the user setting AND
        // iOS Low Power Mode being off. The sampler manages its own
        // CLLocationManager subscription; we just bracket the lifecycle
        // on motion transitions so it's only active during a ride.
        let bikeRouteEnabled = preferences.loadRoutePreferences().bikeRouteLearningEnabled
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if cyclingStarted, bikeRouteEnabled {
            bikeRouteSampler.startRide(at: .now)
        } else if cyclingEnded {
            // Always stop on end, even if the toggle flipped mid-ride.
            // The sampler's own state guards: if no ride was started,
            // stopRide is a no-op that also defensively releases the
            // CLLocationManager subscription in case the OS held it.
            bikeRouteSampler.stopRide(at: .now)
        }

        previousMotion = motion

        let context = location?.context ?? .unknown
        let result = autopinner.apply(
            preferences: prefsSnapshot,
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

    /// Phase 6 consumer. When the next-context predictor is confident
    /// the user is about to head to a known anchor, ask the
    /// `WalkingDistanceResolver` to begin warming MapKit walks for the
    /// nearby stations. Fire-and-forget — the resolver's own inflight
    /// dedup absorbs the case where those stations are already being
    /// fetched by the dashboard. Returns immediately; the actual MapKit
    /// requests run on their own.
    private func primePredictedDestinationWalking() {
        let profile = preferences.loadMobilityProfile()
        let anchors = preferences.loadCommuteAnchors()
        let currentContext = location?.context ?? .unknown
        guard currentContext != .unknown else { return }
        guard let plan = predictivePrefetcher.plan(
            profile: profile,
            currentContext: currentContext,
            anchors: anchors
        ) else { return }
        walkingResolver.ensureFresh(
            origin: (lat: plan.origin.latitude, lon: plan.origin.longitude),
            stations: plan.stations
        )
    }

    /// Maintain the persisted `elsewhereSince` timestamp so the head-home
    /// suggester can reason about outing duration across app launches.
    /// Setting fires once when context first transitions to `.elsewhere`;
    /// clears immediately when context returns to a known anchor.
    private func updateElsewhereTracking() {
        let context = location?.context ?? .unknown
        switch context {
        case .elsewhere:
            // First time we're seeing elsewhere this session — stamp it.
            // Idempotent: if the persisted value is non-nil, leave it.
            if preferences.loadElsewhereSince() == nil {
                preferences.saveElsewhereSince(.now)
            }
        case .atHome, .atWork:
            // Back at a known anchor — clear the stamp.
            if preferences.loadElsewhereSince() != nil {
                preferences.saveElsewhereSince(nil)
            }
        case .unknown:
            // Don't change anything — `.unknown` is a transient state.
            break
        }
    }

    // MARK: - Per-service refreshers

    private func refreshTrains(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?,
        closedStations: Set<Int>
    ) async {
        // Build the set of (mapId, stopId?) targets to query the Train Tracker
        // for: tracked stations OR the nearest few + the pinned-line station.
        // Use a parallel Set of (mapId, stopId) pairs so duplicate-detection
        // is O(1) instead of an O(n²) `.contains(where:)` over `targets`.
        var targets: [(mapId: Int, stopId: Int?)] = []
        var seenTargets: Set<TrainTargetKey> = []
        func appendTarget(mapId: Int, stopId: Int?) {
            let key = TrainTargetKey(mapId: mapId, stopId: stopId)
            if seenTargets.insert(key).inserted {
                targets.append((mapId, stopId))
            }
        }

        let visibleTrainPrefs = prefs.trains.filter {
            prefs.isTrainLineVisible($0.line) || prefs.pinnedLine == $0.line
        }
        // Honor tracked stations even if the alerts feed says they're
        // closed — the user picked them on purpose, surface the staleness.
        for pref in visibleTrainPrefs {
            appendTarget(mapId: pref.mapId, stopId: pref.stopId)
        }
        if prefs.isModeVisible(.trains),
           prefs.nearbyDiscoveryEnabled,
           let lastLocation
        {
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
                appendTarget(mapId: candidate.station.id, stopId: nil)
            }
        }

        for tripTrain in prefs.plannedTripPin?.trainLegs ?? [] {
            guard let stationId = tripTrain.stationId else { continue }
            appendTarget(mapId: stationId, stopId: nil)
        }

        // Pinned line: include the user's chosen station (or the nearest
        // station on that line as a fallback), skipping closed stations
        // unless the user explicitly pinned one.
        if let pinned = prefs.pinnedLine, let lastLocation {
            let stationId: Int? = {
                if let explicit = prefs.pinnedStationId,
                   let station = LStationCatalog.byId[explicit],
                   station.servedLines.contains(pinned)
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
            if let stationId {
                appendTarget(mapId: stationId, stopId: nil)
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
        var seenTargets: Set<BusTargetKey> = []
        func appendTarget(route: String, stopId: Int) {
            if seenTargets.insert(BusTargetKey(route: route, stopId: stopId)).inserted {
                targets.append((route, stopId))
            }
        }

        let visibleBusPrefs = prefs.buses.filter {
            prefs.isBusRouteVisible($0.route) || prefs.pinnedBusRoute == $0.route
        }
        for pref in visibleBusPrefs {
            appendTarget(route: pref.route, stopId: pref.stopId)
        }
        if prefs.isModeVisible(.buses),
           prefs.nearbyDiscoveryEnabled,
           let lastLocation
        {
            // Surface predictions for nearby directional coverage (N/S, E/W,
            // diagonal), not just the closest few routes.
            let nearest = corridorResolver.nearbyBusCandidates(
                to: (lastLocation.latitude, lastLocation.longitude),
                radiusMeters: 1_500,
                limitPerCorridor: 2,
                isRouteVisible: prefs.isBusRouteVisible
            )
            for candidate in nearest {
                appendTarget(route: candidate.stop.route, stopId: candidate.stop.id)
            }
        }

        // Pinned bus route: fetch the nearest stops in EACH direction so the
        // dashboard can show both adjacent stop choices for a rider standing
        // between stops.
        if let pinnedRoute = prefs.pinnedBusRoute, let lastLocation {
            if let pinnedStopId = prefs.pinnedBusStopId,
               let explicitStop = BusStopCatalog.stops(onRoute: pinnedRoute).first(where: {
                   $0.id == pinnedStopId
                       && (prefs.pinnedBusDirection == nil
                           || $0.directionLabel == prefs.pinnedBusDirection)
               })
            {
                appendTarget(route: pinnedRoute, stopId: explicitStop.id)
            }

            let directionalStops = busStopResolver.nearestStopsPerDirection(
                onRoute: pinnedRoute,
                to: (lastLocation.latitude, lastLocation.longitude),
                limitPerDirection: 2,
                catalog: BusStopCatalog.all
            )
            for stop in directionalStops {
                appendTarget(route: pinnedRoute, stopId: stop.stop.id)
            }
        }

        for tripBus in prefs.plannedTripPin?.busLegs ?? [] {
            guard let stopId = tripBus.stopId else { continue }
            appendTarget(route: tripBus.route, stopId: stopId)
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
        // Phase 2 (buses): register pending grades from the freshly
        // fetched predictions. The grader's own guard short-circuits the
        // empty case; calling unconditionally keeps behavior consistent.
        await arrivalGrader.ingestBusPredictions(collected)
    }

    private func refreshMetra(
        prefs: UserRoutePreferences,
        lastLocation: LastKnownLocation?
    ) async {
        var targets: [(routeId: String, stationId: String, directionId: Int?)] = []
        var seenTargets: Set<MetraTargetKey> = []
        func appendTarget(routeId: String, stationId: String, directionId: Int?) {
            if seenTargets.insert(MetraTargetKey(routeId: routeId, stationId: stationId)).inserted {
                targets.append((routeId, stationId, directionId))
            }
        }

        let visibleMetraPrefs = prefs.metra.filter {
            prefs.isMetraRouteVisible($0.routeId) || prefs.pinnedMetraRoute == $0.routeId
        }
        if !visibleMetraPrefs.isEmpty {
            for pref in visibleMetraPrefs {
                appendTarget(routeId: pref.routeId, stationId: pref.stationId, directionId: pref.directionId)
            }
        } else if prefs.isModeVisible(.metra),
                  prefs.nearbyDiscoveryEnabled,
                  let lastLocation {
            let nearest = metraStationResolver.nearestPerRoute(
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 5,
                catalog: MetraStationCatalog.all.filter { station in
                    station.servedRoutes.contains(where: prefs.isMetraRouteVisible)
                }
            )
            for entry in nearest {
                appendTarget(routeId: entry.routeId, stationId: entry.station.id, directionId: nil)
            }
        }

        for tripMetra in prefs.plannedTripPin?.metraLegs ?? [] {
            guard let stationId = tripMetra.stationId else { continue }
            appendTarget(routeId: tripMetra.routeId, stationId: stationId, directionId: tripMetra.directionId)
        }

        if let pinnedRoute = prefs.pinnedMetraRoute, let lastLocation {
            if let pinnedStationId = prefs.pinnedMetraStationId,
               let pinnedStation = MetraStationCatalog.station(id: pinnedStationId),
               pinnedStation.servedRoutes.contains(pinnedRoute)
            {
                appendTarget(
                    routeId: pinnedRoute,
                    stationId: pinnedStationId,
                    directionId: prefs.pinnedMetraDirectionId
                )
            }

            let nearest = metraStationResolver.closestStations(
                onRoute: pinnedRoute,
                to: (lastLocation.latitude, lastLocation.longitude),
                limit: 3,
                catalog: MetraStationCatalog.all
            )
            for station in nearest {
                appendTarget(
                    routeId: pinnedRoute,
                    stationId: station.station.id,
                    directionId: prefs.pinnedMetraDirectionId
                )
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
        let plannedStopIds = Set(
            (prefs.plannedTripPin?.intercampusLegs.map(\.stopId) ?? [])
                .filter { IntercampusCatalog.stop(id: $0) != nil }
        )
        let shouldFetchNearby = prefs.includeIntercampus && prefs.isModeVisible(.intercampus)
        guard shouldFetchNearby || prefs.pinnedIntercampusStopId != nil || !plannedStopIds.isEmpty else {
            await store.replaceIntercampusArrivals([])
            return
        }

        var targetStopIds = plannedStopIds
        var trafficPriorityStopIds: Set<String> = []
        if shouldFetchNearby, let lastLocation {
            let origin = (lastLocation.latitude, lastLocation.longitude)
            let nearby = intercampusStopResolver.nearestPerDirection(
                to: origin,
                limitPerDirection: 12,
                catalog: IntercampusCatalog.all
            )
            targetStopIds.formUnion(nearby.map(\.stop.id))
            var priorityDirections: Set<IntercampusDirection> = []
            for entry in nearby where priorityDirections.insert(entry.direction).inserted {
                trafficPriorityStopIds.insert(entry.stop.id)
            }
        }
        if let selectedStopId = prefs.pinnedIntercampusStopId,
           IntercampusCatalog.stop(id: selectedStopId) != nil
        {
            targetStopIds.insert(selectedStopId)
            trafficPriorityStopIds.insert(selectedStopId)
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
            let trafficAdjusted = await intercampusTrafficResolver.applyingTrafficEstimates(
                to: capped,
                priorityStopIds: trafficPriorityStopIds,
                now: .now
            )
            await store.replaceIntercampusArrivals(trafficAdjusted)
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

    /// Refreshes the cached bus-detour list at most once every
    /// `detourRefreshInterval`. Detours change on the order of hours, so
    /// the 30 s refresh ticker would otherwise burn API budget repeating
    /// itself. Scoped to the routes the user actually rides so we don't
    /// download every detour citywide.
    private func refreshDetoursIfNeeded(prefs: UserRoutePreferences) async {
        let now = Date()
        if let last = lastDetoursFetchedAt,
           now.timeIntervalSince(last) < Self.detourRefreshInterval {
            return
        }

        var routes: Set<String> = []
        for pref in prefs.buses where prefs.isBusRouteVisible(pref.route) || prefs.pinnedBusRoute == pref.route {
            routes.insert(pref.route)
        }
        if let pinned = prefs.pinnedBusRoute { routes.insert(pinned) }
        routes.formUnion(prefs.plannedTripPin?.busLegs.map(\.route) ?? [])

        guard !routes.isEmpty else {
            // No bus routes to monitor — clear any stale cached detours so
            // the scorer doesn't trip on outdated state when the user
            // un-pins everything.
            await store.replaceBusDetours([])
            lastDetoursFetchedAt = now
            return
        }

        do {
            let detours = try await busClient.fetchDetours(routes: Array(routes))
            await store.replaceBusDetours(detours)
            lastDetoursFetchedAt = now
        } catch {
            // Soft fail: keep the previous cached detours. A stale
            // detour list is better than no detour signal at all, and
            // `BusDetour.affects(...)` already filters out detours past
            // their `endsAt`.
        }
    }

    /// Refresh CTA bus pattern geometry for the user's pinned/visible
    /// routes. Patterns change rarely (only on detour-version changes), so
    /// an hourly cadence is enough — but we re-fetch sooner whenever the
    /// pinned-route set grows so a newly-tracked route still gets geometry
    /// promptly.
    private func refreshPatternsIfNeeded(prefs: UserRoutePreferences) async {
        var routes: Set<String> = []
        for pref in prefs.buses where prefs.isBusRouteVisible(pref.route) || prefs.pinnedBusRoute == pref.route {
            routes.insert(pref.route)
        }
        if let pinned = prefs.pinnedBusRoute { routes.insert(pinned) }
        routes.formUnion(prefs.plannedTripPin?.busLegs.map(\.route) ?? [])

        guard !routes.isEmpty else {
            await store.replaceBusPatterns([])
            lastPatternsFetchedAt = Date()
            lastPatternsRouteSet = []
            return
        }

        let now = Date()
        let stale = lastPatternsFetchedAt.map { now.timeIntervalSince($0) >= Self.patternRefreshInterval } ?? true
        let routesChanged = !routes.isSubset(of: lastPatternsRouteSet)
        guard stale || routesChanged else { return }

        do {
            let patterns = try await busClient.fetchPatterns(routes: Array(routes))
            await store.replaceBusPatterns(patterns)
            lastPatternsFetchedAt = now
            lastPatternsRouteSet = routes
        } catch {
            // Soft fail: stale geometry is better than none.
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
            latestBikeInventory = BikeInventorySnapshot(
                stations: stations,
                eBikes: ebikes,
                fetchedAt: Date()
            )

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

    // MARK: - Portfolio evaluation (Phase 4)

    /// Runs the per-portfolio evaluator + hysteresis state machine for
    /// every portfolio on `prefs.portfolios`. Updates
    /// `latestPortfolioEvaluations` / `latestPortfolioRecommendations`
    /// / `portfolioRevision` for `AppViewModel` to observe.
    ///
    /// Costs nothing when the user has no portfolios — short-circuits
    /// before constructing the snapshot adapter. Otherwise builds one
    /// `PortfolioSnapshot` per refresh tick and reuses it across every
    /// portfolio (the bias / walk readers freeze their state at
    /// construction, so concurrent portfolios see a consistent view).
    ///
    /// Non-`private` because the app-target tests in `CozyFoxTests`
    /// drive it directly via `@testable import CozyFox` — `refreshAll`
    /// is too heavy to integration-test in unit tests.
    func evaluatePortfolios(
        prefs: UserRoutePreferences,
        transitSnapshot: TransitSnapshot,
        closedStations: Set<Int>
    ) {
        // Free path for users without portfolios.
        guard !prefs.portfolios.isEmpty else {
            // Clear any stale state — typically empty already, but
            // covers the case where the user just removed their last
            // portfolio.
            if !portfolioHysteresisState.isEmpty
                || !latestPortfolioEvaluations.isEmpty
                || !latestPortfolioRecommendations.isEmpty
            {
                portfolioHysteresisState.removeAll()
                latestPortfolioEvaluations.removeAll()
                latestPortfolioRecommendations.removeAll()
                portfolioRevision &+= 1
            }
            return
        }

        let now = Date()
        let userLocation = location?.lastKnown.map {
            PlannerCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }
        let walker = walkingStore.makeWalkingDistanceReader(now: now)
        let biasReader: any BiasCorrectionReader = biasStore?.makeBiasCorrectionReader()
            ?? EmptyBiasCorrectionReader()
        let snapshot = PortfolioSnapshot(
            snapshot: transitSnapshot,
            now: now,
            userLocation: userLocation,
            walkingDistance: walker,
            biasCorrection: biasReader,
            closedStationIDs: closedStations
        )

        // Drop state for portfolios the user no longer has.
        let activeIDs = Set(prefs.portfolios.map(\.id))
        portfolioHysteresisState = portfolioHysteresisState.filter { activeIDs.contains($0.key) }
        latestPortfolioEvaluations = latestPortfolioEvaluations.filter { activeIDs.contains($0.key) }
        latestPortfolioRecommendations = latestPortfolioRecommendations.filter { activeIDs.contains($0.key) }

        var anyChange = false
        for portfolio in prefs.portfolios {
            let evaluation = portfolioEvaluator.evaluate(portfolio: portfolio, snapshot: snapshot)
            latestPortfolioEvaluations[portfolio.id] = evaluation

            let priorState = portfolioHysteresisState[portfolio.id] ?? .initial
            let outcome = portfolioHysteresis.step(
                state: priorState,
                evaluation: evaluation,
                now: now
            )
            portfolioHysteresisState[portfolio.id] = outcome.state

            if let approvedID = outcome.recommendedID,
               let approvedEval = evaluation.evaluation(for: approvedID)
            {
                // Compute miss-cost for the approved option (not the
                // raw candidate), so the dashboard's annotation lines
                // up with what's actually surfaced.
                let missCost = portfolioMissCostCalculator.missCost(
                    recommended: approvedEval,
                    portfolio: portfolio,
                    snapshot: snapshot
                )
                latestPortfolioRecommendations[portfolio.id] = PortfolioRecommendation(
                    optionID: approvedID,
                    missCost: missCost,
                    changedAt: outcome.state.lastChangedAt ?? now,
                    lowConfidence: approvedEval.confidence < 1.0
                )
            } else {
                latestPortfolioRecommendations.removeValue(forKey: portfolio.id)
            }

            if outcome.didChange { anyChange = true }
        }

        if anyChange {
            portfolioRevision &+= 1
        }
    }
}

// MARK: - Target dedup keys

/// Hashable lookup keys used by the per-service refreshers to dedup their
/// target tuples in O(1) instead of `Array.contains(where:)` scans.
private struct TrainTargetKey: Hashable {
    let mapId: Int
    let stopId: Int?
}

private struct BusTargetKey: Hashable {
    let route: String
    let stopId: Int
}

private struct MetraTargetKey: Hashable {
    let routeId: String
    let stationId: String
}
