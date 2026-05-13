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
