import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public struct MetraBlockView: View {
    public let predictions: [MetraPrediction]
    public let routeLabel: String
    public let stationLabel: String
    public let now: Date

    public init(
        predictions: [MetraPrediction],
        routeLabel: String,
        stationLabel: String,
        now: Date = .now
    ) {
        self.predictions = predictions
        self.routeLabel = routeLabel
        self.stationLabel = stationLabel
        self.now = now
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
            if let first = predictions.first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                    MetraDepartureTimeView(
                        date: first.arrivalAt,
                        size: .md,
                        tone: first.isDelayed || first.isCanceled ? .alert : .primary,
                        accessibilityPrefix: "Next Metra train on \(routeLabel) departs at"
                    )
                    if first.isDelayed || first.isCanceled {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(ChicagoPalette.starRed)
                            .accessibilityHidden(true)
                    }
                }
                HeadwayDotStrip(
                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                    accent: MetraStationCatalog.route(id: routeLabel)?.swiftUIColor ?? ChicagoPalette.bahama,
                    now: now
                )
            } else {
                Text("No Metra")
                    .font(ChicagoTypography.displaySM(relativeTo: .footnote))
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
