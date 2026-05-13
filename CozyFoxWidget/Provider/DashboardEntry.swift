import WidgetKit
import TransitCache
import TransitModels

struct DashboardEntry: TimelineEntry {
    let date: Date
    let snapshot: TransitSnapshot
    let configuration: DashboardConfigurationIntent

    static func placeholder() -> DashboardEntry {
        DashboardEntry(
            date: .now,
            snapshot: .empty,
            configuration: DashboardConfigurationIntent()
        )
    }
}
