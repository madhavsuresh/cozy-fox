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
