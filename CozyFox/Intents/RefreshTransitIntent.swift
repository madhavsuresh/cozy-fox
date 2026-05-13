import AppIntents
import Foundation
import WidgetKit

/// Lets users refresh from a Control Center widget, the Action Button, or
/// Shortcuts. Posts a notification that the running app instance picks up.
struct RefreshTransitIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Cozy Fox"
    static let description = IntentDescription(
        "Pulls the latest train, bus, and Divvy information."
    )
    static let openAppWhenRun: Bool = false
    static let isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .refreshRequested, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

extension Notification.Name {
    static let refreshRequested = Notification.Name("net.thoughtbison.cozyfox.refreshRequested")
}
