import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct SmallDashboardView: View {
    let entry: DashboardEntry

    var body: some View {
        if let arrival = entry.snapshot.trainArrivals.first {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(arrival.line.swiftUIColor)
                        .frame(width: 14, height: 14)
                    Text(arrival.line.shortName)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if entry.snapshot.activeAlerts.contains(where: { $0.impactedLineColors.contains(arrival.line) }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Text(arrival.destinationName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                ForEach(entry.snapshot.trainArrivals.prefix(2), id: \.id) { item in
                    Text(ArrivalFormatter.label(for: item).shortText)
                        .font(.title3.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        } else if let pick = entry.snapshot.nearestBike {
            BikeBlockView(pick: pick)
        } else {
            VStack {
                Image(systemName: "tram").foregroundStyle(.secondary)
                Text("No data yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
