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
    public static let onboardingComplete = "onboardingComplete"
}
