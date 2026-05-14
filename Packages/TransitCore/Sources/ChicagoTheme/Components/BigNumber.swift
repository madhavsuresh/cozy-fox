import SwiftUI

/// A massive countdown number lockup — the headline value at the top of
/// a card. Renders the integer in Big Shoulders Display with tabular
/// numerals (so a `9 → 10` tick doesn't reflow), and an optional unit
/// label stacked below in Big Shoulders Text.
///
/// Optimised for **glance**: per Cleveland & McGill, position-on-axis is
/// the most accurate visual encoding, but raw magnitude is the most
/// accurate *single-number* readout when typography is the channel. Pair
/// this with a `HeadwayDotStrip` to give both — the number for the next
/// arrival and the strip for the pattern.
public struct BigNumber: View {
    public enum Size: Sendable {
        case sm   // 28pt — inline rows
        case md   // 44pt — secondary headline
        case lg   // 64pt — card headline
        case xl   // 88pt — hero (live activity, large widget)

        var point: CGFloat {
            switch self { case .sm: 28; case .md: 44; case .lg: 64; case .xl: 88 }
        }
        var relativeTo: Font.TextStyle {
            switch self { case .sm: .title2; case .md, .lg, .xl: .largeTitle }
        }
        var unitSize: CGFloat {
            switch self { case .sm: 10; case .md: 12; case .lg: 14; case .xl: 16 }
        }
    }

    public enum Tone: Sendable {
        case primary    // Gray.darkest
        case accent     // flagBlue
        case warning    // gold
        case alert      // starRed
        case onDark     // white (for live activity / dark widget)
    }

    private let value: String
    private let unit: String?
    private let size: Size
    private let tone: Tone
    private let accessibilityValueLabel: String?

    public init(_ value: Int,
                unit: String? = nil,
                size: Size = .lg,
                tone: Tone = .primary,
                accessibilityLabel: String? = nil) {
        self.value = String(value)
        self.unit = unit
        self.size = size
        self.tone = tone
        self.accessibilityValueLabel = accessibilityLabel
    }

    public init(_ value: String,
                unit: String? = nil,
                size: Size = .lg,
                tone: Tone = .primary,
                accessibilityLabel: String? = nil) {
        self.value = value
        self.unit = unit
        self.size = size
        self.tone = tone
        self.accessibilityValueLabel = accessibilityLabel
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
            Text(value)
                .font(ChicagoTypography.bigNumber(size.point, relativeTo: size.relativeTo))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            if let unit {
                Text(unit)
                    .font(ChicagoTypography.body(.medium, size: size.unitSize, relativeTo: .footnote))
                    .foregroundStyle(color.opacity(0.75))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityValueLabel
                            ?? "\(value)\(unit.map { " \($0)" } ?? "")")
    }

    private var color: Color {
        switch tone {
        case .primary: ChicagoPalette.Gray.darkest
        case .accent:  ChicagoPalette.flagBlue
        case .warning: ChicagoPalette.gold
        case .alert:   ChicagoPalette.starRed
        case .onDark:  .white
        }
    }
}
