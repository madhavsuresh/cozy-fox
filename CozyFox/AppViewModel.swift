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

    var snapshot: TransitSnapshot = .empty
    /// Latest live vehicle positions for whatever the user has pinned — used
    /// by the dashboard's progress strip. Refreshed each cycle from
    /// `RefreshCoordinator.latestPositions`.
    var vehiclePositions: [VehiclePosition] = []
    var isRefreshing: Bool = false
    var activeDetail: DetailDestination?
    var isOnboardingComplete: Bool
    /// Bumped when the persisted route pins change outside dashboard-local
    /// controls, e.g. an automatic commute pin during refresh.
    var pinRevision: Int = 0

    /// User-controlled toggle for the 30 s ticker. Persisted to prefs.
    /// Observable so the dashboard switch reflects state instantly.
    var liveUpdatesEnabled: Bool = true
    /// Mirrors `ProcessInfo.processInfo.isLowPowerModeEnabled`. Updated via
    /// `NSProcessInfoPowerStateDidChange` so toggling Low Power Mode in
    /// Settings.app immediately pauses/resumes the ticker.
    var isLowPowerMode: Bool = false

    /// Whether the 30 s ticker should actually run right now.
    var liveUpdatesActive: Bool { liveUpdatesEnabled && !isLowPowerMode }

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
        arrivalBiasStore: ArrivalBiasStore? = nil
    ) {
        self.store = store
        self.preferences = preferences
        self.location = location
        self.refreshCoordinator = refreshCoordinator
        self.walkingStore = walkingStore
        self.walkingResolver = WalkingDistanceResolver(store: walkingStore)
        self.arrivalBiasStore = arrivalBiasStore ?? ArrivalBiasStore()
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
        let walkingHydration = Task { await walkingStore.hydrateFromDiskIfNeeded() }
        let arrivalBiasHydration = Task { await arrivalBiasStore.hydrateFromDiskIfNeeded() }
        liveUpdatesEnabled = preferences.loadRoutePreferences().liveUpdatesEnabled
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        registerPowerStateObserver()
        migrateMobilityProfileIfNeeded()
        await loadCachedSnapshot()
        await walkingHydration.value
        await arrivalBiasHydration.value
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
        if force || snapshot == .empty || snapshot.isAnythingStale(ttl: 30) {
            let pinsChanged = await refreshCoordinator.refreshAll()
            if pinsChanged {
                pinRevision += 1
            }
        }
        await loadCachedSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func loadCachedSnapshot() async {
        snapshot = await store.currentSnapshot()
        vehiclePositions = refreshCoordinator.latestPositions.isEmpty
            ? snapshot.vehiclePositions
            : refreshCoordinator.latestPositions
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
                trainDestination: prefs.pinnedTrainDestination,
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
