import Foundation
import CoreLocation
import TransitModels

/// Live `LocationProvider` backed by `CLLocationManager`. Strictly opt-in:
/// region monitoring only fires on Home / Work crossings, and a one-shot
/// foreground read is used only when the app is in the foreground.
public final class LiveLocationProvider: NSObject, LocationProvider, @unchecked Sendable {
    private let manager: CLLocationManager
    private let continuation: AsyncStream<RegionEvent>.Continuation
    public let events: AsyncStream<RegionEvent>

    private var pendingOneShot: CheckedContinuation<LastKnownLocation?, Never>?

    override public init() {
        var localContinuation: AsyncStream<RegionEvent>.Continuation!
        let stream = AsyncStream<RegionEvent> { c in localContinuation = c }
        self.continuation = localContinuation
        self.events = stream
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.activityType = .otherNavigation
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
