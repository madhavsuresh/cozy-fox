import Foundation
import Observation
import TransitModels

/// Owns `LocationProvider`, tracks region events, and exposes a derived
/// `CommuteContext` for the rest of the app. Persists `LastKnownLocation` and
/// emits `onContextChanged` callbacks the app can use to kick refreshes /
/// start Live Activities.
@MainActor
@Observable
public final class LocationCoordinator {
    public private(set) var authorization: LocationAuthorization = .notDetermined
    public private(set) var context: CommuteContext = .unknown
    public private(set) var lastKnown: LastKnownLocation?
    /// Last-read motion classification from the M-series motion coprocessor.
    /// Updated on region events, foreground reads, and `refreshMotion()`.
    public private(set) var motion: MotionContext = .unknown
    public var anchors: CommuteAnchors

    public var onContextChanged: ((@MainActor (CommuteContext) -> Void))?
    public var onRegionExit: ((@MainActor (CommuteDirection) -> Void))?

    private let provider: LocationProvider
    private let preferences: PreferencesStoreLike
    private var eventTask: Task<Void, Never>?

    public init(
        provider: LocationProvider = LiveLocationProvider(),
        preferences: PreferencesStoreLike,
        anchors: CommuteAnchors = .empty
    ) {
        self.provider = provider
        self.preferences = preferences
        self.anchors = anchors
        self.authorization = provider.currentAuthorization()
        self.lastKnown = preferences.loadLastKnownLocation()
        self.context = inferContext(from: self.lastKnown)
        recordObservation(context: self.context, source: .foreground, motion: nil)
    }

    public func bootstrap() {
        provider.startMonitoring(home: anchors.home, work: anchors.work)
        listenForEvents()
    }

    public func updateAnchors(_ anchors: CommuteAnchors) {
        self.anchors = anchors
        provider.startMonitoring(home: anchors.home, work: anchors.work)
        context = inferContext(from: lastKnown)
    }

    public func refreshLocation() async {
        guard let loc = await provider.requestOneShotLocation() else { return }
        lastKnown = loc
        preferences.saveLastKnownLocation(loc)
        let motion = await provider.currentMotion()
        self.motion = motion
        let newContext = inferContext(from: loc)
        recordObservation(context: newContext, source: .foreground, motion: motion, at: loc.recordedAt)
        if newContext != context {
            context = newContext
            onContextChanged?(newContext)
        }
    }

    /// Reads the current motion classification from the provider and caches
    /// it for observable consumers. Returns the same value it caches.
    @discardableResult
    public func refreshMotion() async -> MotionContext {
        let motion = await provider.currentMotion()
        self.motion = motion
        return motion
    }

    public func requestPermission() {
        provider.requestWhenInUseAuthorization()
    }

    /// Triggers the iOS Core Motion permission prompt the first time it is
    /// called. Subsequent calls are no-ops. Safe to call before the user has
    /// granted location permission.
    public func primeMotionAuthorization() {
        provider.primeMotionAuthorization()
    }

    private func listenForEvents() {
        eventTask?.cancel()
        let stream = provider.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: RegionEvent) async {
        let motion = await provider.currentMotion()
        self.motion = motion
        switch event {
        case .enteredHome:
            context = .atHome
            recordObservation(context: .atHome, source: .enteredHome, motion: motion)
            onContextChanged?(.atHome)
        case .exitedHome:
            context = .elsewhere
            recordObservation(context: .elsewhere, source: .exitedHome, direction: .toWork, motion: motion)
            onContextChanged?(.elsewhere)
            onRegionExit?(.toWork)
        case .enteredWork:
            context = .atWork
            recordObservation(context: .atWork, source: .enteredWork, motion: motion)
            onContextChanged?(.atWork)
        case .exitedWork:
            context = .elsewhere
            recordObservation(context: .elsewhere, source: .exitedWork, direction: .toHome, motion: motion)
            onContextChanged?(.elsewhere)
            onRegionExit?(.toHome)
        }
    }

    private func recordObservation(
        context: CommuteContext,
        source: MobilityProfile.Observation.Source,
        direction: CommuteDirection? = nil,
        motion: MotionContext? = nil,
        at date: Date = .now
    ) {
        guard context != .unknown else { return }
        var profile = preferences.loadMobilityProfile()
        profile.recordObservation(
            context: context,
            source: source,
            direction: direction,
            motion: motion,
            at: date,
            calendar: SystemCalendar.chicago
        )
        preferences.saveMobilityProfile(profile)
    }

    private func inferContext(from location: LastKnownLocation?) -> CommuteContext {
        guard let location else { return .unknown }
        if let home = anchors.home, isWithinRadius(location, anchor: home) { return .atHome }
        if let work = anchors.work, isWithinRadius(location, anchor: work) { return .atWork }
        return .elsewhere
    }

    private func isWithinRadius(_ location: LastKnownLocation, anchor: CommuteAnchors.Anchor) -> Bool {
        let lat1 = location.latitude * .pi / 180
        let lat2 = anchor.latitude * .pi / 180
        let dLat = (anchor.latitude - location.latitude) * .pi / 180
        let dLon = (anchor.longitude - location.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        let meters = 6_371_008.8 * c
        return meters <= RegionIdentifiers.radiusMeters
    }
}

/// Avoid a cyclic dependency on TransitCache by giving the coordinator the
/// minimal preferences surface it needs.
public protocol PreferencesStoreLike: Sendable {
    func loadLastKnownLocation() -> LastKnownLocation?
    func saveLastKnownLocation(_ location: LastKnownLocation)
    func loadMobilityProfile() -> MobilityProfile
    func saveMobilityProfile(_ profile: MobilityProfile)
}

private enum SystemCalendar {
    static var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
