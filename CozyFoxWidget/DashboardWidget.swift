import WidgetKit
import SwiftUI
import TransitUI

struct DashboardWidget: Widget {
    let kind = "CozyFoxDashboard"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DashboardConfigurationIntent.self,
            provider: DashboardProvider()
        ) { entry in
            DashboardEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.97, green: 0.97, blue: 0.99),
                            Color(red: 0.92, green: 0.93, blue: 0.97),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .configurationDisplayName("Cozy Fox")
        .description("Trains, buses, and Divvy e-bikes at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DashboardEntryView: View {
    let entry: DashboardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallDashboardView(entry: entry)
        case .systemLarge:
            LargeDashboardView(entry: entry)
        default:
            MediumWidgetWrapper(entry: entry)
        }
    }
}
