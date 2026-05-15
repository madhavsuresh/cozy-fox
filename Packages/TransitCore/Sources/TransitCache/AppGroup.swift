import Foundation

/// Shared App Group identifier used by app, widget, and live activity targets.
public enum AppGroup {
    public static let identifier = "group.net.thoughtbison.cozyfox"

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

public enum UserDefaultsKey {
    public static let routePreferences = "routePreferences"
    public static let commuteAnchors = "commuteAnchors"
    public static let lastKnownLocation = "lastKnownLocation"
    public static let mobilityProfile = "mobilityProfile"
    public static let onboardingComplete = "onboardingComplete"
    /// Wall-clock when `LocationCoordinator.context` first transitioned to
    /// `.elsewhere` in the current "out" session. Cleared when the user is
    /// observed back at home or work. Persisted so cold-starts after an
    /// extended outing know how long the user has been away — important
    /// for the "head home" suggestion gate.
    public static let elsewhereSince = "elsewhereSince"
}
