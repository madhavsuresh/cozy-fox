import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public struct BusBlockView: View {
    public let predictions: [BusPrediction]
    public let routeLabel: String
    public let stopLabel: String
    public let now: Date

    public init(predictions: [BusPrediction],
                routeLabel: String,
                stopLabel: String,
                now: Date = .now) {
        self.predictions = predictions
        self.routeLabel = routeLabel
        self.stopLabel = stopLabel
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                RouteBadge(bus: routeLabel, size: .sm)
                Text(stopLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let first = predictions.first {
                let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(now) / 60).rounded()))
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next bus on route \(routeLabel)"
                    )
                    if first.isDelayed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(ChicagoPalette.starRed)
                            .accessibilityHidden(true)
                    }
                }
                HeadwayDotStrip(
                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                    accent: ChicagoPalette.flagBlue,
                    now: now
                )
            } else {
                Text("No buses")
                    .font(ChicagoTypography.displaySM(relativeTo: .footnote))
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
