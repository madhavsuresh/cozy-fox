import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct BusDetailScreen: View {
    let route: String
    let stopId: Int
    @Environment(AppViewModel.self) private var model

    var predictions: [BusPrediction] {
        let raw = model.snapshot.busPredictions
            .filter {
                ($0.route == route || route.isEmpty)
                && ($0.stopId == stopId || stopId == 0)
            }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        return BusPredictionFilter.filter(
            raw,
            reliabilities: model.busReliabilities,
            level: model.busPredictionFilterLevel
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if predictions.isEmpty {
                        Text("No predictions")
                            .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                            .padding(ChicagoSpacing.md)
                    } else if let first = predictions.first {
                        let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
                        ChicagoCard(title: "Route \(route)",
                                    eyebrow: first.stopName,
                                    ornament: .icon(systemName: "bus.fill"),
                                    accent: ChicagoPalette.Mode.bus) {
                            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                                BigNumber(
                                    minutes,
                                    unit: "min",
                                    size: .lg,
                                    tone: first.isDelayed ? .alert : .primary,
                                    accessibilityLabel: "\(minutes) minutes to next bus"
                                )
                                let detailReliabilities = model.busReliabilities
                                HeadwayDotStrip(
                                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                                    accent: ChicagoPalette.Mode.bus,
                                    complications: predictions.prefix(8).map {
                                        detailReliabilities[$0.id]?.headwayComplication
                                    }
                                )
                                if model.showBusReliabilityDebug {
                                    BusReliabilityDebugOverlay(
                                        predictions: Array(predictions.prefix(6)),
                                        reliabilities: detailReliabilities
                                    )
                                }
                                Rectangle()
                                    .fill(ChicagoPalette.Gray.light.opacity(0.28))
                                    .frame(height: ChicagoSpacing.Stroke.hairline)
                                ForEach(predictions.prefix(8), id: \.id) { p in
                                    predictionRow(p)
                                }
                            }
                        }
                    }
                }
                .padding(ChicagoSpacing.md)
            }
            .background(ChicagoPalette.Surface.background)
            .navigationTitle("Route \(route)")
        }
    }

    private func predictionRow(_ p: BusPrediction) -> some View {
        let minutes = max(0, Int((p.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
        return HStack(spacing: ChicagoSpacing.sm) {
            RouteBadge(bus: p.route, size: .sm)
            VStack(alignment: .leading) {
                Text("→ \(p.destinationName)")
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text(p.stopName)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
            }
            Spacer()
            BigNumber(
                minutes,
                unit: "min",
                size: .sm,
                tone: p.isDelayed ? .alert : .primary,
                accessibilityLabel: "\(minutes) minutes"
            )
        }
    }
}
