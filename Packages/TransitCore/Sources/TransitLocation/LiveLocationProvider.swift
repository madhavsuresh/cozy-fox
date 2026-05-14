import Foundation
import CoreLocation
import TransitModels
#if os(iOS)
import CoreMotion
#endif

/// Live `LocationProvider` backed by `CLLocationManager` and (on iOS)
/// `CMMotionActivityManager`. Strictly opt-in: region monitoring only fires
/// on Home / Work crossings, foreground reads are one-shot, and motion is
/// read passively from the M-series motion coprocessor's ring buffer.
public final class LiveLocationProvider: NSObject, LocationProvider, @unchecked Sendable {
    private let manager: CLLocationManager
    #if os(iOS)
    private let motionManager: CMMotionActivityManager
    private let motionQueue: OperationQueue
    #endif
    private let continuation: AsyncStream<RegionEvent>.Continuation
    public let events: AsyncStream<RegionEvent>

    private var pendingOneShot: CheckedContinuation<LastKnownLocation?, Never>?

    override public init() {
        var localContinuation: AsyncStream<RegionEvent>.Continuation!
        let stream = AsyncStream<RegionEvent> { c in localContinuation = c }
        self.continuation = localContinuation
        self.events = stream
        self.manager = CLLocationManager()
        #if os(iOS)
        self.motionManager = CMMotionActivityManager()
        self.motionQueue = OperationQueue()
        self.motionQueue.qualityOfService = .utility
        #endif
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        #if os(iOS)
        manager.activityType = .otherNavigation
        #endif
        manager.pausesLocationUpdatesAutomatically = true
    }

    public func currentAuthorization() -> LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .authorizedWhenInUse
        case .authorizedAlways: return .authorizedAlways
        @unknown default: return .notDetermined
        }
    }

    public func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    public func requestOneShotLocation() async -> LastKnownLocation? {
        guard manager.authorizationStatus != .denied,
              manager.authorizationStatus != .restricted else {
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<LastKnownLocation?, Never>) in
            pendingOneShot = cont
            manager.requestLocation()
        }
    }

    public func startMonitoring(home: CommuteAnchors.Anchor?, work: CommuteAnchors.Anchor?) {
        // Always clear existing regions first.
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        if let home {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
                radius: RegionIdentifiers.radiusMeters,
                identifier: RegionIdentifiers.home
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        if let work {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: work.latitude, longitude: work.longitude),
                radius: RegionIdentifiers.radiusMeters,
                identifier: RegionIdentifiers.work
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
    }

    public func stopMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
    }

    #if os(iOS)
    public func currentMotion() async -> MotionContext {
        guard CMMotionActivityManager.isActivityAvailable() else { return .unknown }
        let end = Date()
        let start = end.addingTimeInterval(-5 * 60)
        return await withCheckedContinuation { (cont: CheckedContinuation<MotionContext, Never>) in
            motionManager.queryActivityStarting(from: start, to: end, to: motionQueue) { activities, _ in
                let context = Self.dominantMotion(from: activities)
                cont.resume(returning: context)
            }
        }
    }

    public func primeMotionAuthorization() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let end = Date()
        let start = end.addingTimeInterval(-60)
        motionManager.queryActivityStarting(from: start, to: end, to: motionQueue) { _, _ in }
    }

    /// Picks the most-recent confident activity from a CMMotionActivity slice.
    /// Prefers `medium`/`high` confidence; falls back to the most recent
    /// non-unknown activity if everything is low-confidence.
    static func dominantMotion(from activities: [CMMotionActivity]?) -> MotionContext {
        guard let activities, !activities.isEmpty else { return .unknown }
        let sorted = activities.sorted { $0.startDate > $1.startDate }
        let confident = sorted.first { $0.confidence != .low && motionContext(for: $0) != .unknown }
        if let confident { return motionContext(for: confident) }
        let anyKnown = sorted.first { motionContext(for: $0) != .unknown }
        return anyKnown.map { motionContext(for: $0) } ?? .unknown
    }

    private static func motionContext(for activity: CMMotionActivity) -> MotionContext {
        if activity.stationary { return .stationary }
        if activity.walking { return .walking }
        if activity.running { return .running }
        if activity.cycling { return .cycling }
        if activity.automotive { return .automotive }
        return .unknown
    }
    #endif
}

extension LiveLocationProvider: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            pendingOneShot?.resume(returning: nil)
            pendingOneShot = nil
            return
        }
        let result = LastKnownLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            recordedAt: location.timestamp,
            source: .foreground
        )
        pendingOneShot?.resume(returning: result)
        pendingOneShot = nil
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        pendingOneShot?.resume(returning: nil)
        pendingOneShot = nil
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        switch region.identifier {
        case RegionIdentifiers.home: continuation.yield(.enteredHome)
        case RegionIdentifiers.work: continuation.yield(.enteredWork)
        default: break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        switch region.identifier {
        case RegionIdentifiers.home: continuation.yield(.exitedHome)
        case RegionIdentifiers.work: continuation.yield(.exitedWork)
        default: break
        }
    }
}
