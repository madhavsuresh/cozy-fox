import Foundation
import TransitCache

/// Reads / writes the transit API keys.
///
/// We use the App Group's shared `UserDefaults` rather than the Keychain.
/// Rationale: CTA and Metra keys are public-API rate-limit identifiers,
/// not credentials — losing encryption-at-rest doesn't expose anything that
/// access to the app's container wouldn't already expose. UserDefaults gives
/// us reliable persistence across rebuilds with zero entitlement plumbing and
/// is shared automatically with the widget extension.
enum APIKeys {
    enum Service: String {
        case trainTracker = "cta.train.tracker"
        case busTracker = "cta.bus.tracker"
        case metra = "metra.gtfs"

        /// Key used inside the App Group defaults dictionary.
        fileprivate var defaultsKey: String { "apiKey.\(rawValue)" }
    }

    /// Shared App Group defaults if available, otherwise `.standard` so the
    /// app still works in unusual environments (e.g., simulators where the
    /// group container isn't provisioned).
    private static var store: UserDefaults {
        AppGroup.sharedDefaults ?? .standard
    }

    static func read(_ service: Service) -> String? {
        let value = store.string(forKey: service.defaultsKey)
        return (value?.isEmpty == false) ? value : nil
    }

    @discardableResult
    static func write(_ service: Service, value: String) -> Bool {
        if value.isEmpty {
            store.removeObject(forKey: service.defaultsKey)
        } else {
            store.set(value, forKey: service.defaultsKey)
        }
        // UserDefaults writes are synchronous to the in-memory dictionary and
        // flushed to disk on the next runloop tick. There's no error channel
        // to consult; readback verification (in SettingsScreen) is the only
        // way to confirm. Treat as success.
        return true
    }

    @discardableResult
    static func delete(_ service: Service) -> Bool {
        store.removeObject(forKey: service.defaultsKey)
        return true
    }
}
