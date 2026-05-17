import Foundation
import Observation
import SwiftUI
import TransitCache
import TransitDomain
import TransitLocation
import TransitModels
import WidgetKit

@MainActor
@Observable
final class AppViewModel {
    let store: TransitStore
    let preferences: PreferencesStore
    let location: LocationCoordinator
    let refreshCoordinator: RefreshCoordinator
    let walkingStore: WalkingDistanceStore
    let walkingResolver: WalkingDistanceResolver
    let arrivalBiasStore: ArrivalBiasStore
    /// Phase 5b Tier 2 — recorded bike rides. Optional surface ("rides
    /// recorded: N") in Settings; no consumer in the prediction
    /// pipeline yet. Hydrated alongside the other learning stores.
    let bikeRouteStore: BikeRouteStore
    /// Persistent tracker for dashboard-suggestion dismissals. Backs
    /// the head-home tile (eventually) and the pleasant-surprise
    /// suggester. Wiped by Settings → "Reset learning".
    let suggestionSuppression: SuggestionSuppression

    var snapshot: TransitSnapshot = .empty
    /// Latest live vehicle positions for whatever the user has pinned — used
    /// by the dashboard's progress strip. Refreshed each cycle from
    /// `RefreshCoordinator.latestPositions`.
    var vehiclePositions: [VehiclePosition] = []
    /// Per-bus rolling history (last ~8 obs per vehicle) mirrored from
    /// `RefreshCoordinator.latestBusVehicleHistory`. Drives the geometry
    /// blender's speed estimate in phase 3b.
    var busVehicleHistory: [String: [BusVehicleHistorySample]] = [:]
    /// In-memory mirror of `RefreshCoordinator.latestBikeInventory`, observed
    /// by the dashboard's trip-pin Divvy chips. Held here (not in
    /// `TransitSnapshot`) so the persistent cache never sees the full station
    /// list.
    var bikeInventory: BikeInventorySnapshot = .empty
    var isRefreshing: Bool = false
    var activeDetail: DetailDestination?
    var isOnboardingComplete: Bool
    /// Bumped when the persisted route pins change outside dashboard-local
    /// controls, e.g. an automatic commute pin during refresh.
    var pinRevision: Int = 0
    /// Per-portfolio per-tick evaluation, mirrored from
    /// `RefreshCoordinator.latestPortfolioEvaluations`. Keyed by
    /// `RoutePortfolio.id`. Empty when the user has no portfolios.
    var portfolioEvaluations: [UUID: PortfolioEvaluation] = [:]
    /// Hysteresis-approved recommendation per portfolio. `changedAt`
    /// is stable across ticks while the same option holds the slot.
    var portfolioRecommendations: [UUID: PortfolioRecommendation] = [:]
    /// Mirror of `RefreshCoordinator.portfolioRevision`. Consumers can
    /// `.onChange(of: portfolioRevision)` to react to recommendation
    /// changes without diffing the full map.
    var portfolioRevision: Int = 0

    /// Mirror of `RefreshCoordinator.feedFetchStates`. The dashboard's empty-
    /// state branches read this to decide between "Fetching arrivals…" (we
    /// haven't successfully heard back yet) and "No upcoming arrivals" (the
    /// upstream answered, the answer is genuinely empty). Replaces the older
    /// pattern of branching off the global `isRefreshing` flag, which flipped
    /// false the moment the fetch loop ended regardless of outcome.
    var feedFetchStates: FeedFetchStates = .init()

    /// Has this feed responded successfully recently enough that we trust an
    /// empty result for it? Convenience over `feedFetchStates.hasFreshFetch`.
    func hasFreshFetch(for feed: TransitFeed) -> Bool {
        feedFetchStates.hasFreshFetch(for: feed)
    }

    /// Per-target variant — prefer this on pinned cards so a sibling
    /// target's success can't trick the UI into saying "no upcoming X"
    /// when the pinned target's own call failed.
    func hasFreshFetch(forTarget key: TargetFetchKey) -> Bool {
        feedFetchStates.hasFreshFetch(forTarget: key)
    }

    /// Age of the last successful fetch for a specific pinned target, in
    /// seconds. Nil if no successful fetch has been recorded yet.
    func age(forTarget key: TargetFetchKey) -> TimeInterval? {
        feedFetchStates.age(forTarget: key)
    }

    /// Bucketed staleness for the indicator dot/label. Re-derived on each
    /// observation, so a 30 s ticker tick is enough to age the display.
    func staleness(forTarget key: TargetFetchKey, now: Date = .now) -> Staleness {
        Staleness.from(age: feedFetchStates.age(forTarget: key, now: now))
    }

    /// User-controlled toggle for the 30 s ticker. Persisted to prefs.
    /// Observable so the dashboard switch reflects state instantly.
    var liveUpdatesEnabled: Bool = true
    /// Mirrors `ProcessInfo.processInfo.isLowPowerModeEnabled`. Updated via
    /// `NSProcessInfoPowerStateDidChange` so toggling Low Power Mode in
    /// Settings.app immediately pauses/resumes the ticker.
    var isLowPowerMode: Bool = false
    /// Mirror of `UserRoutePreferences.busPredictionFilterLevel` so
    /// SwiftUI observers re-render the dashboard immediately when the
    /// setting changes. Hydrated at init and rewritten by
    /// `setBusPredictionFilterLevel(_:)`.
    var busPredictionFilterLevel: BusPredictionFilterLevel = .default
    /// Mirror of `UserRoutePreferences.showBusReliabilityDebug` so
    /// dashboard surfaces re-render the debug overlay immediately on
    /// toggle.
    var showBusReliabilityDebug: Bool = false
    /// Mirror of `UserRoutePreferences.trainPredictionFilterLevel`.
    /// Same shape and lifecycle as `busPredictionFilterLevel`; the two
    /// are independent knobs because train and bus reliability have
    /// different distributions and a rider may want to trust one feed
    /// more than the other.
    var trainPredictionFilterLevel: TrainPredictionFilterLevel = .default
    /// Mirror of `UserRoutePreferences.showTrainReliabilityDebug`.
    var showTrainReliabilityDebug: Bool = false

    /// Whether the 30 s ticker should actually run right now.
    var liveUpdatesActive: Bool { liveUpdatesEnabled && !isLowPowerMode }

    /// Bus predictions filtered through `BusReliabilityScorer` and the
    /// user's chosen `BusPredictionFilterLevel`. By default
    /// (`inclusive`) ghost predictions are dropped before any dashboard
    /// surface sees them; the user can opt into stricter levels or
    /// "show everything" via Settings. See `docs/BUS_RELIABILITY.md`.
    ///
    /// Computed each access from `snapshot.busPredictions` and
    /// `vehiclePositions`; `@Observable` tracks the inputs.
    var displayableBusPredictions: [BusPrediction] {
        let reliabilities = busReliabilities
        let bins = snapshot.busResidualBins
        let patterns = snapshot.busPatterns
        let vehicles = vehiclePositions
        let history = busVehicleHistory
        let level = busPredictionFilterLevel
        let now = Date()

        // For medium/high-confidence rows: phase 3b geometry blend first
        // (uses pdist + recent speed to produce an independent ETA, then
        // blends with CTA), then phase 4b residual calibration on top of
        // that. Low-confidence/unreliable rows pass through uncalibrated
        // — they already mute the BigNumber, and shifting them would just
        // paper over the uncertainty.
        let processed: [BusPrediction] = snapshot.busPredictions.map { pred in
            guard let reliability = reliabilities[pred.id] else { return pred }
            switch reliability.state {
            case .highConfidence, .mediumConfidence:
                let matchedVehicle = vehicles.first {
                    $0.mode == .bus && $0.id == pred.vehicleId
                }
                let matchedPattern = BusPatternGeometry.pattern(
                    for: matchedVehicle?.patternId,
                    route: pred.route,
                    directionName: pred.directionName,
                    in: patterns
                )
                let blended = BusGeometryBlender.blend(
                    prediction: pred,
                    matchedPattern: matchedPattern,
                    latestVehicle: matchedVehicle,
                    history: history[pred.vehicleId] ?? [],
                    now: now
                ).prediction
                return BusPredictionCalibrator.calibrate(
                    blended,
                    using: bins,
                    calendar: .currentChicago
                ).prediction
            case .lowConfidence, .unreliable, .doNotDisplay:
                return pred
            }
        }
        return BusPredictionFilter.filter(
            processed,
            reliabilities: reliabilities,
            level: level
        )
    }

    /// Per-prediction reliability assessments keyed by `BusPrediction.id`.
    /// Available for debug surfaces and styling (mute low-confidence).
    var busReliabilities: [String: BusArrivalReliability] {
        BusReliabilityScorer().catalogedAssessments(
            for: snapshot.busPredictions,
            vehicles: vehiclePositions,
            activeDetours: snapshot.busDetours,
            patterns: snapshot.busPatterns,
            stopDetourStates: snapshot.busStopDetourStates
        )
    }

    /// Per-arrival reliability assessments keyed by `Arrival.id`.
    /// Mirror of `busReliabilities`. Cheap to compute (the scorer is a
    /// pure function over snapshot state) so we don't memoize; SwiftUI's
    /// `@Observable` tracking re-renders only when the inputs change.
    var trainReliabilities: [String: TrainArrivalReliability] {
        TrainReliabilityScorer().catalogedAssessments(
            for: snapshot.trainArrivals,
            vehiclePositions: vehiclePositions,
            alerts: snapshot.activeAlerts
        )
    }

    /// Apply the user's train reliability filter to `arrivals`. Use
    /// from dashboard surfaces that have already filtered by line /
    /// station / destination upstream, since we only want the
    /// reliability filter to act on rows the user otherwise asked for.
    /// Mirror of the bus side's `displayableBusPredictions`, but as a
    /// function so each surface can apply it after its own upstream
    /// filtering. Train arrivals are stored uncalibrated — no Phase 4
    /// residual quantile binning yet, so the filter is the only
    /// step needed.
    func filteredDisplayableTrainArrivals(_ arrivals: [Arrival]) -> [Arrival] {
        TrainPredictionFilter.filter(
            arrivals,
            reliabilities: trainReliabilities,
            level: trainPredictionFilterLevel
        )
    }

    /// In-memory suppression for the head-home tile. When non-nil and
    /// in the future, the tile stays hidden even if
    /// `HomewardSuggester.shouldSurface` would otherwise pass its gates.
    /// Reset on app cold-start by design: a 2-hour suppression buys the
    /// rest of one outing; tomorrow is a fresh chance.
    var homewardSuppressedUntil: Date?

    /// User dismissed the head-home tile. Pause it for `seconds` so the
    /// suggester stops firing this session.
    func suppressHomeward(for seconds: TimeInterval) {
        homewardSuppressedUntil = Date().addingTimeInterval(seconds)
    }

    /// Foreground refresh ticker — polls CTA every 30 s while the app is
    /// active so the dashboard and Live Activity reflect delays in close to
    /// real time. iOS suspends background `Task.sleep` aggressively, so this
    /// effectively pauses when backgrounded and resumes via `onScenePhase`.
    private var refreshTicker: Task<Void, Never>?
    private var powerStateObserver: NSObjectProtocol?
    private static let refreshInterval: UInt64 = 30 * 1_000_000_000  // 30s

    init(
        store: TransitStore,
        preferences: PreferencesStore,
        location: LocationCoordinator,
        refreshCoordinator: RefreshCoordinator,
        walkingStore: WalkingDistanceStore,
        arrivalBiasStore: ArrivalBiasStore? = nil,
        bikeRouteStore: BikeRouteStore? = nil,
        suggestionSuppression: SuggestionSuppression? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.location = location
        self.refreshCoordinator = refreshCoordinator
        self.walkingStore = walkingStore
        self.walkingResolver = WalkingDistanceResolver(store: walkingStore)
        self.arrivalBiasStore = arrivalBiasStore ?? ArrivalBiasStore()
        self.bikeRouteStore = bikeRouteStore ?? BikeRouteStore()
        self.suggestionSuppression = suggestionSuppression ?? SuggestionSuppression()
        self.isOnboardingComplete = preferences.isOnboardingComplete

        location.onContextChanged = { [weak self] context in
            guard let self else { return }
            Task { await self.refreshIfNeeded(force: true) }
        }
        location.onRegionExit = { [weak self] direction in
            guard let self else { return }
            Task { await self.refreshCoordinator.handleRegionExit(direction: direction) }
        }
    }

    func bootstrap() async {
        location.bootstrap()
        // One-shot: walk distances used to live in per-app Caches; the
        // widget now reads the same file from the App Group container.
        // Move any existing cache so users don't lose their warm data.
        WalkingDistanceStore.migrateLegacyCacheIfNeeded()
        let walkingHydration = Task { await walkingStore.hydrateFromDiskIfNeeded() }
        let arrivalBiasHydration = Task { await arrivalBiasStore.hydrateFromDiskIfNeeded() }
        let bikeRouteHydration = Task { await bikeRouteStore.hydrateFromDiskIfNeeded() }
        let suppressionHydration = Task { await suggestionSuppression.hydrateFromDiskIfNeeded() }
        let initialPrefs = preferences.loadRoutePreferences()
        liveUpdatesEnabled = initialPrefs.liveUpdatesEnabled
        busPredictionFilterLevel = initialPrefs.busPredictionFilterLevel
        showBusReliabilityDebug = initialPrefs.showBusReliabilityDebug
        trainPredictionFilterLevel = initialPrefs.trainPredictionFilterLevel
        showTrainReliabilityDebug = initialPrefs.showTrainReliabilityDebug
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        registerPowerStateObserver()
        migrateMobilityProfileIfNeeded()
        await loadCachedSnapshot()
        await walkingHydration.value
        await arrivalBiasHydration.value
        await bikeRouteHydration.value
        await suppressionHydration.value
        await refreshIfNeeded()
        reconcileRefreshTicker()
    }

    /// Ensures any pre-summary mobility profile on disk gets folded into the
    /// derived summary before the 14-day raw retention starts pruning rows.
    /// Idempotent; the summarizer only consumes observations newer than its
    /// stored cursor.
    private func migrateMobilityProfileIfNeeded() {
        let profile = preferences.loadMobilityProfile()
        let updated = MobilityProfileSummarizer().refresh(profile)
        if updated.summary != profile.summary {
            preferences.saveMobilityProfile(updated)
        }
    }

    /// Called from the SwiftUI scene-phase observer in `CozyFoxApp`.
    func onScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Re-check Low Power Mode on foreground — the user may have
            // toggled it in Settings while we were in the background.
            isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            reconcileRefreshTicker()
            // First foreground hit also gets an immediate fresh fetch.
            Task { await refreshIfNeeded(force: true) }
        case .background, .inactive:
            stopRefreshTicker()
        @unknown default:
            break
        }
    }

    /// User flipped the dashboard toggle. Persist + reconcile.
    func setLiveUpdatesEnabled(_ enabled: Bool) {
        liveUpdatesEnabled = enabled
        var prefs = preferences.loadRoutePreferences()
        prefs.liveUpdatesEnabled = enabled
        preferences.saveRoutePreferences(prefs)
        reconcileRefreshTicker()
    }

    /// Persist the user's bus-prediction filter level. Updates the
    /// `@Observable` mirror so any view reading
    /// `displayableBusPredictions` re-renders immediately.
    func setBusPredictionFilterLevel(_ level: BusPredictionFilterLevel) {
        busPredictionFilterLevel = level
        var prefs = preferences.loadRoutePreferences()
        prefs.busPredictionFilterLevel = level
        preferences.saveRoutePreferences(prefs)
    }

    /// Persist the user's debug-overlay toggle.
    func setShowBusReliabilityDebug(_ enabled: Bool) {
        showBusReliabilityDebug = enabled
        var prefs = preferences.loadRoutePreferences()
        prefs.showBusReliabilityDebug = enabled
        preferences.saveRoutePreferences(prefs)
    }

    /// Persist the user's train-arrival filter level. Mirrors
    /// `setBusPredictionFilterLevel`.
    func setTrainPredictionFilterLevel(_ level: TrainPredictionFilterLevel) {
        trainPredictionFilterLevel = level
        var prefs = preferences.loadRoutePreferences()
        prefs.trainPredictionFilterLevel = level
        preferences.saveRoutePreferences(prefs)
    }

    /// Persist the user's train debug-overlay toggle.
    func setShowTrainReliabilityDebug(_ enabled: Bool) {
        showTrainReliabilityDebug = enabled
        var prefs = preferences.loadRoutePreferences()
        prefs.showTrainReliabilityDebug = enabled
        preferences.saveRoutePreferences(prefs)
    }

    private func reconcileRefreshTicker() {
        if liveUpdatesActive {
            startRefreshTicker()
        } else {
            stopRefreshTicker()
        }
    }

    private func startRefreshTicker() {
        refreshTicker?.cancel()
        refreshTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
                if Task.isCancelled { return }
                await self?.refreshIfNeeded(force: true)
            }
        }
    }

    private func stopRefreshTicker() {
        refreshTicker?.cancel()
        refreshTicker = nil
    }

    /// Listen for Low Power Mode toggles so we can pause/resume immediately
    /// when the user enables Low Power Mode in Settings.app.
    private func registerPowerStateObserver() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.reconcileRefreshTicker()
            }
        }
    }

    func completeOnboarding() {
        preferences.isOnboardingComplete = true
        isOnboardingComplete = true
        Task { await refreshIfNeeded(force: true) }
    }

    func refreshIfNeeded(force: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await location.refreshLocation()
        var didRefresh = false
        if force || snapshot == .empty || snapshot.isAnythingStale(ttl: 30) {
            let pinsChanged = await refreshCoordinator.refreshAll()
            if pinsChanged {
                pinRevision += 1
            }
            didRefresh = true
        }
        await loadCachedSnapshot()
        // `RefreshCoordinator.refreshAll()` already called
        // `WidgetCenter.shared.reloadAllTimelines()`. Only re-trigger the
        // widget when we *didn't* run the coordinator (snapshot was fresh)
        // so we don't pay the cross-process IPC cost twice per cycle.
        if !didRefresh {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func loadCachedSnapshot() async {
        snapshot = await store.currentSnapshot()
        vehiclePositions = refreshCoordinator.latestPositions.isEmpty
            ? snapshot.vehiclePositions
            : refreshCoordinator.latestPositions
        busVehicleHistory = refreshCoordinator.latestBusVehicleHistory
        bikeInventory = refreshCoordinator.latestBikeInventory
        portfolioEvaluations = refreshCoordinator.latestPortfolioEvaluations
        portfolioRecommendations = refreshCoordinator.latestPortfolioRecommendations
        portfolioRevision = refreshCoordinator.portfolioRevision
        feedFetchStates = refreshCoordinator.feedFetchStates

        // One-shot diagnostic line for the bus reliability pipeline.
        // Stream live via:
        //     log stream --predicate 'subsystem == "net.thoughtbison.cozyfox"' --info --debug
        // or use Console.app with the same predicate. See
        // `BusReliabilityDebugLogger` for the field shape.
        BusReliabilityDebugLogger.log(
            snapshot: snapshot,
            vehiclePositions: vehiclePositions,
            busVehicleHistory: busVehicleHistory
        )
        TrainReliabilityDebugLogger.log(
            snapshot: snapshot,
            vehiclePositions: vehiclePositions
        )
    }

    func saveManualRoutePreferences(_ update: (inout UserRoutePreferences) -> Void) {
        var prefs = preferences.loadRoutePreferences()
        update(&prefs)
        prefs.plannedTripPin = nil
        prefs.markManualPin()
        preferences.saveRoutePreferences(prefs)
        recordManualRouteChoice(prefs)
        pinRevision += 1
    }

    func clearLocalMobilityProfile() {
        preferences.clearMobilityProfile()
    }

    func savePlannedTripPin(_ pin: PlannedTripPin) {
        var prefs = preferences.loadRoutePreferences()
        prefs.plannedTripPin = pin
        prefs.markManualPin()
        preferences.saveRoutePreferences(prefs)
        recordManualRouteChoice(prefs)
        pinRevision += 1
        Task { await refreshIfNeeded(force: true) }
    }

    func updatePlannedTripPin(_ pin: PlannedTripPin) {
        var prefs = preferences.loadRoutePreferences()
        guard prefs.plannedTripPin?.id == pin.id else { return }
        prefs.plannedTripPin = pin
        preferences.saveRoutePreferences(prefs)
        pinRevision += 1
    }

    func clearPlannedTripPin() {
        var prefs = preferences.loadRoutePreferences()
        guard prefs.plannedTripPin != nil else { return }
        prefs.plannedTripPin = nil
        preferences.saveRoutePreferences(prefs)
        pinRevision += 1
        Task { await refreshIfNeeded(force: true) }
    }

    func saveIntercampusPreferences(_ update: (inout UserRoutePreferences) -> Void) {
        var prefs = preferences.loadRoutePreferences()
        update(&prefs)
        preferences.saveRoutePreferences(prefs)
        pinRevision += 1
    }

    func setHomeAnchor(latitude: Double, longitude: Double) {
        var anchors = preferences.loadCommuteAnchors()
        anchors.home = .init(latitude: latitude, longitude: longitude, label: "Home")
        preferences.saveCommuteAnchors(anchors)
        location.updateAnchors(anchors)
        pinRevision += 1
        Task { await refreshIfNeeded(force: true) }
    }

    func setWorkAnchor(latitude: Double, longitude: Double) {
        var anchors = preferences.loadCommuteAnchors()
        anchors.work = .init(latitude: latitude, longitude: longitude, label: "Work")
        preferences.saveCommuteAnchors(anchors)
        location.updateAnchors(anchors)
        pinRevision += 1
        Task { await refreshIfNeeded(force: true) }
    }

    private func recordManualRouteChoice(_ prefs: UserRoutePreferences) {
        var profile = preferences.loadMobilityProfile()
        let direction = inferredManualPinDirection()
        let calendar = SystemClock().calendar
        let now = Date.now
        let origin = location.lastKnown.map {
            MobilityProfile.RouteLocation.bucketed(
                latitude: $0.latitude,
                longitude: $0.longitude,
                label: location.context.rawValue
            )
        }
        let destination = prefs.plannedTripPin?.destination.routeLocation

        func record(
            line: LineColor? = nil,
            stationId: Int? = nil,
            trainDestination: String? = nil,
            busRoute: String? = nil,
            busDirection: String? = nil,
            metraRoute: String? = nil,
            metraStationId: String? = nil,
            metraDirectionId: Int? = nil
        ) {
            profile.recordRouteObservation(
                direction: direction,
                context: location.context,
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
                motion: location.motion,
                at: now,
                calendar: calendar
            )
        }

        if let trip = prefs.plannedTripPin {
            for train in trip.trainLegs {
                record(
                    line: train.line,
                    stationId: train.stationId,
                    trainDestination: train.destinationName
                )
            }
            for bus in trip.busLegs {
                record(busRoute: bus.route, busDirection: bus.directionLabel)
            }
            for metra in trip.metraLegs {
                record(
                    metraRoute: metra.routeId,
                    metraStationId: metra.stationId,
                    metraDirectionId: metra.directionId
                )
            }
        } else {
            record(
                line: prefs.pinnedLine,
                stationId: prefs.pinnedStationId,
                // For mobility-profile recording purposes, treat the
                // multi-destination pin as the first destination —
                // the observation is a heuristic, not a precise
                // ledger; recording one canonical choice keeps
                // downstream pattern aggregation stable.
                trainDestination: prefs.pinnedTrainDestinations?.first,
                busRoute: prefs.pinnedBusRoute,
                busDirection: prefs.pinnedBusDirection,
                metraRoute: prefs.pinnedMetraRoute,
                metraStationId: prefs.pinnedMetraStationId,
                metraDirectionId: prefs.pinnedMetraDirectionId
            )
        }
        preferences.saveMobilityProfile(profile)
    }

    private func inferredManualPinDirection() -> CommuteDirection {
        switch location.context {
        case .atHome: return .toWork
        case .atWork, .elsewhere: return .toHome
        case .unknown:
            return CommutePlanner().preferredDirection(context: .unknown)
        }
    }

    func handleDeepLink(_ url: URL) {
        if let destination = DetailDestination.parse(url: url) {
            activeDetail = destination
        }
    }
}

private extension PlannedTripPin.Destination {
    var routeLocation: MobilityProfile.RouteLocation? {
        guard let latitude, let longitude else { return nil }
        return MobilityProfile.RouteLocation.bucketed(
            latitude: latitude,
            longitude: longitude,
            label: title
        )
    }
}

enum DetailDestination: Identifiable, Hashable {
    case train(stationId: Int)
    case bus(route: String, stopId: Int)
    case metra(route: String, stationId: String)
    case bikeNearest

    var id: String {
        switch self {
        case .train(let id): "train-\(id)"
        case .bus(let r, let s): "bus-\(r)-\(s)"
        case .metra(let r, let s): "metra-\(r)-\(s)"
        case .bikeNearest: "bike-nearest"
        }
    }

    static func parse(url: URL) -> DetailDestination? {
        // Schemes look like cozyfox://train/40380 or cozyfox://bus/22/1234
        let parts = url.pathComponents.filter { $0 != "/" } + [url.host].compactMap { $0 }
        // The host part is the destination type; remaining are ids.
        guard let host = url.host else { return nil }
        switch host {
        case "train":
            if let raw = url.pathComponents.last, let id = Int(raw) {
                return .train(stationId: id)
            }
        case "bus":
            let comps = url.pathComponents.filter { !["/", ""].contains($0) }
            if comps.count >= 2, let stop = Int(comps[1]) {
                return .bus(route: comps[0], stopId: stop)
            }
        case "metra":
            let comps = url.pathComponents.filter { !["/", ""].contains($0) }
            if comps.count >= 2 {
                return .metra(route: comps[0], stationId: comps[1])
            }
        case "bike":
            return .bikeNearest
        default:
            break
        }
        _ = parts
        return nil
    }
}
