import ChicagoTheme
import SwiftUI
import TransitUI
import WidgetKit

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
                    ChicagoPalette.Surface.card
                }
                // Clamp Dynamic Type so massive accessibility sizes don't
                // overflow the widget container.
                .dynamicTypeSize(.medium ... .accessibility2)
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
