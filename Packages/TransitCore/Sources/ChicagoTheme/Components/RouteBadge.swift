import SwiftUI
import TransitModels

/// A compact, high-contrast badge identifying a CTA L line or a bus
/// route. The only place in the app where CTA brand colours appear —
/// every other surface uses the Chicago palette. Riders recognise the
/// Red Line *by red*; that's wayfinding, not decoration, and we
/// preserve it intentionally.
///
/// The badge auto-picks an accessible text colour based on the line's
/// luminance (yellow and pink lines use black; the rest use white).
public struct RouteBadge: View {
    public enum Kind: Sendable {
        case lLine(LineColor)
        case bus(route: String)
    }

    public enum Size: Sendable {
        case sm, md, lg

        var horizontalPadding: CGFloat {
            switch self { case .sm: 6; case .md: 8; case .lg: 12 }
        }
        var verticalPadding: CGFloat {
            switch self { case .sm: 2; case .md: 3; case .lg: 5 }
        }
        var fontStyle: Font.TextStyle {
            switch self { case .sm: .caption; case .md: .footnote; case .lg: .headline }
        }
        var fontSize: CGFloat {
            switch self { case .sm: 11; case .md: 13; case .lg: 18 }
        }
    }

    private let kind: Kind
    private let size: Size

    public init(_ kind: Kind, size: Size = .md) {
        self.kind = kind
        self.size = size
    }

    public init(line: LineColor, size: Size = .md) {
        self.kind = .lLine(line)
        self.size = size
    }

    public init(bus route: String, size: Size = .md) {
        self.kind = .bus(route: route)
        self.size = size
    }

    public var body: some View {
        Text(label)
            .font(badgeFont)
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(textColor)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(backgroundColor,
                        in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm))
            .accessibilityLabel(accessibleLabel)
    }

    // MARK: - Composition

    private var label: String {
        switch kind {
        case .lLine(let line): line.shortName
        case .bus(let route): "#\(route)"
        }
    }

    private var accessibleLabel: String {
        switch kind {
        case .lLine(let line): line.displayName
        case .bus(let route): "Bus route \(route)"
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .lLine(let line): line.swiftUIColor
        case .bus: ChicagoPalette.flagBlue
        }
    }

    private var textColor: Color {
        switch kind {
        case .lLine(let line): line.contrastingText
        case .bus: .white
        }
    }

    private var badgeFont: Font {
        switch size {
        case .sm: ChicagoTypography.displaySM(relativeTo: .caption)
        case .md: ChicagoTypography.displaySM(relativeTo: .footnote)
        case .lg: ChicagoTypography.displayMD(relativeTo: .headline)
        }
    }
}
