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

    public func loadMobilityProfile() -> MobilityProfile {
        guard let data = defaults.data(forKey: UserDefaultsKey.mobilityProfile) else {
            return .empty
        }
        return (try? decoder.decode(MobilityProfile.self, from: data)) ?? .empty
    }

    public func saveMobilityProfile(_ profile: MobilityProfile) {
        if let data = try? encoder.encode(profile) {
            defaults.set(data, forKey: UserDefaultsKey.mobilityProfile)
        }
    }

    public func clearMobilityProfile() {
        defaults.removeObject(forKey: UserDefaultsKey.mobilityProfile)
    }

    public var isOnboardingComplete: Bool {
        get { defaults.bool(forKey: UserDefaultsKey.onboardingComplete) }
        nonmutating set { defaults.set(newValue, forKey: UserDefaultsKey.onboardingComplete) }
    }

    /// First moment in the current "out" session — when context flipped
    /// to `.elsewhere`. Persisted across launches so the head-home tile
    /// can reason about long outings even after the app is force-quit.
    public func loadElsewhereSince() -> Date? {
        let interval = defaults.double(forKey: UserDefaultsKey.elsewhereSince)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    public func saveElsewhereSince(_ date: Date?) {
        if let date {
            defaults.set(date.timeIntervalSinceReferenceDate, forKey: UserDefaultsKey.elsewhereSince)
        } else {
            defaults.removeObject(forKey: UserDefaultsKey.elsewhereSince)
        }
    }
}
