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
                ?? entry.snapshot.trainArrivals.first?.line,
            busRoute: entry.preferences.plannedTripPin?.bus?.route
                ?? entry.snapshot.busPredictions.first?.route,
            metraRoute: entry.preferences.plannedTripPin?.metra?.routeId
                ?? entry.snapshot.metraPredictions.first?.routeId
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
