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
                Divider()
                alertsRow(relevantAlerts)
            }
        }
    }

    private var displayedAlerts: [ServiceAlert] {
        entry.snapshot.activeAlerts.filtered(
            forLine: entry.snapshot.trainArrivals.first?.line,
            busRoute: entry.snapshot.busPredictions.first?.route
        )
    }

    private func alertsRow(_ alerts: [ServiceAlert]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading) {
                ForEach(alerts.prefix(2), id: \.id) { alert in
                    Text(alert.headline)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
