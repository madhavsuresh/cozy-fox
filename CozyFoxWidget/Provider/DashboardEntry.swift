import WidgetKit
import TransitCache
import TransitModels

struct DashboardEntry: TimelineEntry {
    let date: Date
    let snapshot: TransitSnapshot
    let preferences: UserRoutePreferences
    let configuration: DashboardConfigurationIntent

    static func placeholder() -> DashboardEntry {
        DashboardEntry(
            date: .now,
            snapshot: .empty,
            preferences: .empty,
            configuration: DashboardConfigurationIntent()
        )
    }
}
