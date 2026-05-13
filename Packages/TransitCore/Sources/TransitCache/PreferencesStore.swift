import Foundation
import TransitModels

/// Bridges the shared App Group UserDefaults to Codable preference types so the
/// widget can read them synchronously. Sendable wrapper for cross-isolation use.
///
/// `UserDefaults` is thread-safe per Apple's documentation, so we mark the
/// stored reference `nonisolated(unsafe)` rather than wrapping in an actor.
public struct PreferencesStore: Sendable {
    public nonisolated(unsafe) let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults? = AppGroup.sharedDefaults) {
        self.defaults = defaults ?? .standard
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.encoder = e
        self.decoder = d
    }

    public func loadRoutePreferences() -> UserRoutePreferences {
        guard let data = defaults.data(forKey: UserDefaultsKey.routePreferences) else {
            return .empty
        }
        return (try? decoder.decode(UserRoutePreferences.self, from: data)) ?? .empty
    }

    public func saveRoutePreferences(_ prefs: UserRoutePreferences) {
        if let data = try? encoder.encode(prefs) {
            defaults.set(data, forKey: UserDefaultsKey.routePreferences)
        }
    }

    public func loadCommuteAnchors() -> CommuteAnchors {
        guard let data = defaults.data(forKey: UserDefaultsKey.commuteAnchors) else {
            return .empty
        }
        return (try? decoder.decode(CommuteAnchors.self, from: data)) ?? .empty
    }

    public func saveCommuteAnchors(_ anchors: CommuteAnchors) {
        if let data = try? encoder.encode(anchors) {
            defaults.set(data, forKey: UserDefaultsKey.commuteAnchors)
        }
    }

    public func loadLastKnownLocation() -> LastKnownLocation? {
        guard let data = defaults.data(forKey: UserDefaultsKey.lastKnownLocation) else {
            return nil
        }
        return try? decoder.decode(LastKnownLocation.self, from: data)
    }

    public func saveLastKnownLocation(_ location: LastKnownLocation) {
        if let data = try? encoder.encode(location) {
            defaults.set(data, forKey: UserDefaultsKey.lastKnownLocation)
        }
    }

    public var isOnboardingComplete: Bool {
        get { defaults.bool(forKey: UserDefaultsKey.onboardingComplete) }
        nonmutating set { defaults.set(newValue, forKey: UserDefaultsKey.onboardingComplete) }
    }
}
