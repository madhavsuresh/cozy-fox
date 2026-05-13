import AppIntents
import WidgetKit

struct DashboardConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Configure Cozy Fox"
    static let description = IntentDescription("Pin specific routes or let the widget pick based on where you are.")

    @Parameter(title: "Pin a specific train station", default: false)
    var pinTrainStation: Bool

    @Parameter(title: "Pin a specific bus stop", default: false)
    var pinBusStop: Bool

    @Parameter(title: "Show service alerts", default: true)
    var showAlerts: Bool
}
