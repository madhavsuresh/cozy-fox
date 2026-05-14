import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct LargeDashboardView: View {
    let entry: DashboardEntry

    var body: some View {
        VStack(spacing: 0) {
            MediumWidgetWrapper(entry: entry)
                .frame(maxHeight: .infinity)
            let relevantAlerts = displayedAlerts
            if entry.configuration.showAlerts, !relevantAlerts.isEmpty {
                Rectangle()
                    .fill(ChicagoPalette.cornflower.opacity(0.4))
                    .frame(height: ChicagoSpacing.Stroke.hairline)
                    .padding(.horizontal, ChicagoSpacing.sm)
                alertsRow(relevantAlerts)
            }
        }
    }

    private var displayedAlerts: [ServiceAlert] {
        entry.snapshot.activeAlerts.filtered(
            forLine: entry.preferences.plannedTripPin?.train?.line
                ?? entry.preferences.pinnedLine
                ?? entry.snapshot.trainArrivals.first(where: {
                    entry.preferences.isTrainLineVisible($0.line)
                })?.line,
            busRoute: entry.preferences.plannedTripPin?.bus?.route
                ?? entry.preferences.pinnedBusRoute
                ?? entry.snapshot.busPredictions.first(where: {
                    entry.preferences.isBusRouteVisible($0.route)
                })?.route,
            metraRoute: entry.preferences.plannedTripPin?.metra?.routeId
                ?? entry.preferences.pinnedMetraRoute
                ?? entry.snapshot.metraPredictions.first(where: {
                    entry.preferences.isMetraRouteVisible($0.routeId)
                })?.routeId
        )
    }

    private func alertsRow(_ alerts: [ServiceAlert]) -> some View {
        HStack(alignment: .top, spacing: ChicagoSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ChicagoPalette.starRed)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(alerts.prefix(2), id: \.id) { alert in
                    Text(alert.headline)
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.sm)
    }
}
