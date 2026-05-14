import ChicagoTheme
import SwiftUI
import TransitModels

public struct MetraDepartureTimeView: View {
    public enum Size: Sendable {
        case sm
        case md
        case lg

        var point: CGFloat {
            switch self {
            case .sm: 28
            case .md: 44
            case .lg: 64
            }
        }

        var relativeTo: Font.TextStyle {
            switch self {
            case .sm: .title2
            case .md, .lg: .largeTitle
            }
        }
    }

    public let date: Date
    public let size: Size
    public let tone: BigNumber.Tone
    public let accessibilityPrefix: String

    public init(
        date: Date,
        size: Size = .md,
        tone: BigNumber.Tone = .primary,
        accessibilityPrefix: String = "Departs at"
    ) {
        self.date = date
        self.size = size
        self.tone = tone
        self.accessibilityPrefix = accessibilityPrefix
    }

    public var body: some View {
        Text(MetraDepartureFormatter.timeString(date))
            .font(ChicagoTypography.bigNumber(size.point, relativeTo: size.relativeTo))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityLabel("\(accessibilityPrefix) \(MetraDepartureFormatter.accessibilityString(date))")
    }

    private var color: Color {
        switch tone {
        case .primary: ChicagoPalette.Gray.darkest
        case .accent: ChicagoPalette.flagBlue
        case .warning: ChicagoPalette.gold
        case .alert: ChicagoPalette.starRed
        case .onDark: .white
        }
    }
}

public struct MetraDepartureTimesView: View {
    public let predictions: [MetraPrediction]
    public let maxCount: Int
    public let size: MetraDepartureTimeView.Size
    public let tone: BigNumber.Tone
    public let accessibilityPrefix: String

    public init(
        predictions: [MetraPrediction],
        maxCount: Int = 3,
        size: MetraDepartureTimeView.Size = .sm,
        tone: BigNumber.Tone = .primary,
        accessibilityPrefix: String = "Departs at"
    ) {
        self.predictions = predictions
        self.maxCount = maxCount
        self.size = size
        self.tone = tone
        self.accessibilityPrefix = accessibilityPrefix
    }

    public var body: some View {
        if displayed.isEmpty {
            Text("—")
                .font(ChicagoTypography.bigNumber(size.point, relativeTo: size.relativeTo))
                .foregroundStyle(ChicagoPalette.Gray.light)
                .accessibilityLabel("No departures")
        } else {
            HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                ForEach(displayed, id: \.id) { prediction in
                    Text(MetraDepartureFormatter.timeString(prediction.arrivalAt))
                        .font(ChicagoTypography.bigNumber(size.point, relativeTo: size.relativeTo))
                        .foregroundStyle(color(for: prediction))
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var displayed: [MetraPrediction] {
        Array(predictions.prefix(maxCount))
    }

    private var accessibilityLabel: String {
        let times = displayed
            .map { MetraDepartureFormatter.accessibilityString($0.arrivalAt) }
            .joined(separator: ", ")
        return "\(accessibilityPrefix) \(times)"
    }

    private func color(for prediction: MetraPrediction) -> Color {
        if prediction.isDelayed || prediction.isCanceled {
            return ChicagoPalette.starRed
        }
        return switch tone {
        case .primary: ChicagoPalette.Gray.darkest
        case .accent: ChicagoPalette.flagBlue
        case .warning: ChicagoPalette.gold
        case .alert: ChicagoPalette.starRed
        case .onDark: .white
        }
    }
}

public struct MetraDepartureListView: View {
    public enum Density: Sendable {
        case compact
        case regular

        var timeWidth: CGFloat {
            switch self {
            case .compact: 52
            case .regular: 62
            }
        }

        var timeFont: Font {
            switch self {
            case .compact:
                ChicagoTypography.body(.medium, size: 13, relativeTo: .caption)
                    .monospacedDigit()
            case .regular:
                ChicagoTypography.body(.medium, size: 16, relativeTo: .subheadline)
                    .monospacedDigit()
            }
        }

        var destinationFont: Font {
            switch self {
            case .compact: ChicagoTypography.body(.regular, relativeTo: .caption2)
            case .regular: ChicagoTypography.body(.medium, relativeTo: .caption)
            }
        }

        var detailFont: Font {
            ChicagoTypography.body(.regular, relativeTo: .caption2)
        }
    }

    public let predictions: [MetraPrediction]
    public let maxCount: Int
    public let density: Density
    public let showsTrainNumber: Bool
    public let accessibilityPrefix: String

    public init(
        predictions: [MetraPrediction],
        maxCount: Int = 3,
        density: Density = .regular,
        showsTrainNumber: Bool = false,
        accessibilityPrefix: String = "Metra departures"
    ) {
        self.predictions = predictions
        self.maxCount = maxCount
        self.density = density
        self.showsTrainNumber = showsTrainNumber
        self.accessibilityPrefix = accessibilityPrefix
    }

    public var body: some View {
        if displayed.isEmpty {
            Text("No departures")
                .font(density.detailFont)
                .foregroundStyle(ChicagoPalette.Gray.medium)
        } else {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                ForEach(displayed, id: \.id) { prediction in
                    row(prediction)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func row(_ prediction: MetraPrediction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
            Text(MetraDepartureFormatter.timeString(prediction.arrivalAt))
                .font(density.timeFont)
                .foregroundStyle(timeColor(for: prediction))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: density.timeWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(MetraDepartureGrouper.displayDestinationName(prediction.destinationName))
                    .font(density.destinationFont)
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsTrainNumber {
                    Text("Train \(prediction.trainNumber)")
                        .font(density.detailFont)
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
            }
        }
    }

    private var displayed: [MetraPrediction] {
        Array(predictions.prefix(maxCount))
    }

    private var accessibilityLabel: String {
        let departures = displayed.map { prediction in
            "\(MetraDepartureFormatter.accessibilityString(prediction.arrivalAt)) to \(MetraDepartureGrouper.displayDestinationName(prediction.destinationName))"
        }
        .joined(separator: ", ")
        return "\(accessibilityPrefix): \(departures)"
    }

    private func timeColor(for prediction: MetraPrediction) -> Color {
        prediction.isDelayed || prediction.isCanceled ? ChicagoPalette.starRed : ChicagoPalette.Gray.darkest
    }
}
