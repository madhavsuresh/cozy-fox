import WidgetKit
import SwiftData
import TransitCache
import TransitModels

struct DashboardProvider: AppIntentTimelineProvider {
    typealias Entry = DashboardEntry
    typealias Intent = DashboardConfigurationIntent

    func placeholder(in context: Context) -> DashboardEntry {
        .placeholder()
    }

    func snapshot(
        for configuration: DashboardConfigurationIntent,
        in context: Context
    ) async -> DashboardEntry {
        DashboardEntry(
            date: .now,
            snapshot: await loadSnapshot(),
            preferences: loadPreferences(),
            configuration: configuration
        )
    }

    func timeline(
        for configuration: DashboardConfigurationIntent,
        in context: Context
    ) async -> Timeline<DashboardEntry> {
        let snapshot = await loadSnapshot()
        let now = Date()

        // Five entries 90 seconds apart — keeps the displayed countdowns roughly
        // accurate without the timeline budget running away. The system reloads
        // earlier if the running app calls `WidgetCenter.reloadAllTimelines()`.
        let entries = (0..<5).map { offset in
            DashboardEntry(
                date: now.addingTimeInterval(Double(offset) * 90),
                snapshot: snapshot,
                preferences: loadPreferences(),
                configuration: configuration
            )
        }

        let next = now.addingTimeInterval(450) // refresh after 7.5 min
        return Timeline(entries: entries, policy: .after(next))
    }

    private func loadSnapshot() -> TransitSnapshot {
        guard let container = try? ModelContainer.sharedAppGroup() else {
            return .empty
        }
        return SnapshotReader(container: container).loadSnapshot()
    }

    private func loadPreferences() -> UserRoutePreferences {
        PreferencesStore().loadRoutePreferences()
    }
}
