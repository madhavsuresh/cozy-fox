import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public struct MetraBlockView: View {
    public let predictions: [MetraPrediction]
    public let routeLabel: String
    public let stationLabel: String
    public let now: Date
    /// Phase 3 bias correction for the headline departure. See
    /// `TrainBlockView.biasCorrection` for the contract.
    public let biasCorrection: ArrivalBiasCorrection?

    public init(
        predictions: [MetraPrediction],
        routeLabel: String,
        stationLabel: String,
        now: Date = .now,
        biasCorrection: ArrivalBiasCorrection? = nil
    ) {
        self.predictions = predictions
        self.routeLabel = routeLabel
        self.stationLabel = stationLabel
        self.now = now
        self.biasCorrection = biasCorrection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                RouteBadge(metra: routeLabel, size: .sm)
                Text(stationLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let group {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(1)
                }
                MetraDepartureListView(
                    predictions: group.departures,
                    maxCount: 2,
                    density: .compact,
                    accessibilityPrefix: "Metra \(group.title.lowercased()) departures"
                )
                if let biasCorrection {
                    Text(biasCorrection.displayText)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .accessibilityLabel(biasCorrection.accessibilityLabel)
                }
                HeadwayDotStrip(
                    arrivals: group.departures.prefix(8).map(\.arrivalAt),
                    accent: MetraStationCatalog.route(id: routeLabel)?.swiftUIColor ?? ChicagoPalette.bahama,
                    now: now
                )
            } else {
                Text("No Metra")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var group: MetraDepartureGroup? {
        MetraDepartureGrouper.groups(from: predictions, limitPerGroup: 3).first
    }
}
