import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct TrainDetailScreen: View {
    let stationId: Int
    @Environment(AppViewModel.self) private var model

    var arrivals: [Arrival] {
        model.snapshot.trainArrivals
            .filter { $0.stationId == stationId || stationId == 0 }
            .sorted { $0.arrivalAt < $1.arrivalAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if arrivals.isEmpty {
                        Text("No predictions")
                            .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                            .padding(ChicagoSpacing.md)
                    }
                    let grouped = Dictionary(grouping: arrivals, by: \.line)
                        .sorted { $0.key.displayName < $1.key.displayName }
                    ForEach(grouped, id: \.key) { line, items in
                        ChicagoCard(title: line.displayName,
                                    eyebrow: items.first?.stationName,
                                    ornament: .icon(systemName: "tram.fill")) {
                            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                                let first = items.first!
                                let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
                                BigNumber(
                                    minutes,
                                    unit: "min",
                                    size: .lg,
                                    tone: first.isDelayed ? .alert : .primary,
                                    accessibilityLabel: "\(minutes) minutes to next \(line.displayName) train"
                                )
                                HeadwayDotStrip(
                                    arrivals: items.prefix(8).map(\.arrivalAt),
                                    accent: line.swiftUIColor
                                )
                                Rectangle()
                                    .fill(ChicagoPalette.cornflower.opacity(0.3))
                                    .frame(height: ChicagoSpacing.Stroke.hairline)
                                ForEach(items.prefix(6), id: \.id) { arrival in
                                    arrivalRow(arrival)
                                }
                            }
                        }
                    }
                }
                .padding(ChicagoSpacing.md)
            }
            .background(ChicagoPalette.Surface.background)
            .navigationTitle(arrivals.first?.stationName ?? "Train")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
        }
    }

    private func arrivalRow(_ arrival: Arrival) -> some View {
        let minutes = max(0, Int((arrival.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
        return HStack(spacing: ChicagoSpacing.sm) {
            RouteBadge(line: arrival.line, size: .sm)
            Text("→ \(arrival.destinationName)")
                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(1)
            Spacer()
            BigNumber(
                minutes,
                unit: "min",
                size: .sm,
                tone: arrival.isDelayed ? .alert : .primary,
                accessibilityLabel: "\(minutes) minutes"
            )
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshIfNeeded(force: true) }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .tint(ChicagoPalette.flagBlue)
    }
}
