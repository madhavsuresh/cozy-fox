@preconcurrency import CoreLocation
import Foundation

/// Subscribes to coarse-grained CLLocation updates during cycling
/// sessions and feeds the recorded samples into `BikeRouteStore` on
/// ride end. Tier 2 of Phase 5b — opt-in, default off, and iOS Low
/// Power Mode overrides the user setting to off regardless.
///
/// Design notes:
/// - Uses a private `CLLocationManager` rather than extending
///   `LocationCoordinator`, because the lifecycle here is fundamentally
///   different (subscribe on-demand during a cycling session vs.
///   region-monitoring forever in the background). Owning the manager
///   means we can `startUpdatingLocation` / `stopUpdatingLocation`
///   cleanly bracketed by motion transitions.
/// - `distanceFilter` = 200 m: captures route topology without burning
///   battery on tiny GPS jitter. A bike at 15 mph crosses 200 m every
///   ~30 seconds, so for a 30-min ride we get ~60 samples — enough for
///   a downstream clustering consumer to recognize the route.
/// - `desiredAccuracy` = nearestTenMeters: matches what we actually
///   need for route fingerprinting; lower energy than `bestForNavigation`.
/// - The sampler is enabled iff the user setting is on AND iOS isn't
///   in Low Power Mode. The caller (`RefreshCoordinator`) re-checks
///   both at every refresh cycle.
@MainActor
final class BikeRouteSampler: NSObject, CLLocationManagerDelegate {
    private let locationManager: CLLocationManager
    private weak var routeStore: BikeRouteStore?

    /// Buffer of samples since the current ride started. `nil` when no
    /// ride is active.
    private var currentRide: ActiveRide?

    private struct ActiveRide {
        let startedAt: Date
        var samples: [BikeRoute.Sample]
    }

    init(routeStore: BikeRouteStore?) {
        self.locationManager = CLLocationManager()
        self.routeStore = routeStore
        super.init()
        self.locationManager.delegate = self
        self.locationManager.distanceFilter = 200
        self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        self.locationManager.pausesLocationUpdatesAutomatically = true
        self.locationManager.activityType = .fitness
    }

    /// Begin a new cycling session. Idempotent — calling while a ride
    /// is already active is a no-op (the existing samples keep
    /// accumulating). The CLLocationManager subscription stays alive
    /// from `startUpdatingLocation()` until `stopRide` flushes the
    /// buffer.
    func startRide(at time: Date) {
        if currentRide != nil { return }
        currentRide = ActiveRide(startedAt: time, samples: [])
        locationManager.startUpdatingLocation()
    }

    /// End the current cycling session. Stops the CLLocationManager
    /// subscription, builds a `BikeRoute` from the accumulated
    /// samples, and hands it to the store. Rides with zero samples
    /// (e.g., the OS never managed a fix during the ride) are
    /// silently discarded.
    @discardableResult
    func stopRide(at time: Date) -> BikeRoute? {
        defer { locationManager.stopUpdatingLocation() }
        guard let ride = currentRide else { return nil }
        currentRide = nil
        guard !ride.samples.isEmpty else { return nil }
        let route = BikeRoute(
            startedAt: ride.startedAt,
            endedAt: time,
            samples: ride.samples
        )
        routeStore?.record(route)
        return route
    }

    var isRecording: Bool { currentRide != nil }

    /// Test hooks.
    var hasActiveRideForTests: Bool { isRecording }
    var bufferedSampleCountForTests: Int { currentRide?.samples.count ?? 0 }

    /// Test hook — synthesize a sample as if it had arrived from the
    /// location manager. Tests can avoid spinning up CoreLocation
    /// entirely.
    func appendSampleForTests(latitude: Double, longitude: Double, at time: Date) {
        currentRide?.samples.append(BikeRoute.Sample(
            latitude: latitude,
            longitude: longitude,
            recordedAt: time
        ))
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let samples = locations.map { location in
            BikeRoute.Sample(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                recordedAt: location.timestamp
            )
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentRide?.samples.append(contentsOf: samples)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        // Errors aren't surfaced — sampling failures just mean the
        // current ride records fewer samples. We don't have a way to
        // recover from a delegate error here that's more useful than
        // letting the next fix come in.
    }
}
