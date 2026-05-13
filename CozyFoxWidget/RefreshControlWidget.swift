import AppIntents
import WidgetKit
import SwiftUI

struct RefreshControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "CozyFoxRefresh") {
            ControlWidgetButton(action: RefreshFromControlIntent()) {
                Label("Refresh transit", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Refresh Cozy Fox")
        .description("Pulls the latest train, bus, and Divvy data.")
    }
}

/// The control widget can't import the app target, so we declare its own intent
/// that reloads widget timelines. The app picks up the reload signal naturally.
struct RefreshFromControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Cozy Fox"
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
