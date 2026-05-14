import Foundation
import TransitModels

/// Test seam. The live impl wraps `CLLocationManager`; tests inject a fake.
public protocol LocationProvider: Sendable {
    func currentAuthorization() -> LocationAuthorization
    func requestWhenInUseAuthorization()
    /// One-shot foreground location read. Returns nil if not authorized.
    func requestOneShotLocation() async -> LastKnownLocation?
    /// Start monitoring two named circular regions (Home / Work).
    func startMonitoring(home: CommuteAnchors.Anchor?, work: CommuteAnchors.Anchor?)
    func stopMonitoring()
    /// Stream of region crossing events.
    var events: AsyncStream<RegionEvent> { get }
    /// Reads the dominant motion classification from the last ~5 minutes of
    /// the motion coprocessor's ring buffer. Near-zero battery cost — the
    /// M-series motion chip is always running and we just query it.
    /// Returns `.unknown` when motion data is unavailable (older device,
    /// denied permission, or no recent samples).
    func currentMotion() async -> MotionContext
    /// Triggers the Core Motion permission prompt by issuing a no-op activity
    /// query. Safe to call repeatedly.
    func primeMotionAuthorization()
}

public extension LocationProvider {
    func currentMotion() async -> MotionContext { .unknown }
    func primeMotionAuthorization() {}
}

public enum LocationAuthorization: String, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorizedWhenInUse
    case authorizedAlways
}

public enum RegionEvent: Sendable, Hashable {
    case enteredHome
    case exitedHome
    case enteredWork
    case exitedWork
}
