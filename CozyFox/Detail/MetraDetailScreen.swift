import ChicagoTheme
import SwiftUI
import TransitModels
import TransitUI

struct MetraDetailScreen: View {
    let route: String
    let stationId: String
    @Environment(AppViewModel.self) private var model

    var predictions: [MetraPrediction] {
        model.snapshot.metraPredictions
            .filter {
                ($0.routeId == route || route.isEmpty)
                    && ($0.stationId == stationId || stationId.isEmpty)
            }
            .sorted { $0.arrivalAt < $1.arrivalAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if predictions.isEmpty {
                        Text("No departures")
                            .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                            .padding(ChicagoSpacing.md)
                    } else if let first = predictions.first {
                        ChicagoCard(title: MetraStationCatalog.route(id: route)?.displayName ?? route,
                                    eyebrow: first.stationName,
                                    ornament: .icon(systemName: "train.side.front.car")) {
                            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                                MetraDepartureTimeView(
                                    date: first.arrivalAt,
                                    size: .lg,
                                    tone: first.isDelayed || first.isCanceled ? .alert : .primary,
                                    accessibilityPrefix: "Next Metra train departs at"
                                )
                                HeadwayDotStrip(
                                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                                    accent: MetraStationCatalog.route(id: route)?.swiftUIColor ?? ChicagoPalette.bahama
                                )
                                Rectangle()
                                    .fill(ChicagoPalette.cornflower.opacity(0.3))
                                    .frame(height: ChicagoSpacing.Stroke.hairline)
                                ForEach(predictions.prefix(8), id: \.id) { prediction in
                                    predictionRow(prediction)
                                }
                            }
                        }
                    }
                }
                .padding(ChicagoSpacing.md)
            }
            .background(ChicagoPalette.Surface.background)
            .navigationTitle(predictions.first?.stationName ?? "Metra")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
        }
    }

    private func predictionRow(_ prediction: MetraPrediction) -> some View {
        HStack(spacing: ChicagoSpacing.sm) {
            RouteBadge(metra: prediction.routeId, size: .sm)
            VStack(alignment: .leading) {
                Text("→ \(prediction.destinationName)")
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text("Train \(prediction.trainNumber)")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
            }
            Spacer()
            MetraDepartureTimeView(
                date: prediction.arrivalAt,
                size: .sm,
                tone: prediction.isDelayed || prediction.isCanceled ? .alert : .primary,
                accessibilityPrefix: "Departs at"
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
