import SwiftUI
import TransitModels

/// A compact, high-contrast badge identifying a CTA L line, CTA bus route,
/// or Metra line. Rail badges use their official line colors; bus badges use
/// the semantic bus accent so they do not read as CTA Blue Line content.
///
/// The badge auto-picks readable text based on each route color's luminance.
public struct RouteBadge: View {
    public enum Kind: Sendable {
        case lLine(LineColor)
        case bus(route: String)
        case metra(routeId: String)
        case amtrak(routeId: String)
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

    public init(metra routeId: String, size: Size = .md) {
        self.kind = .metra(routeId: routeId)
        self.size = size
    }

    public init(amtrak routeId: String, size: Size = .md) {
        self.kind = .amtrak(routeId: routeId)
        self.size = size
    }

    public var body: some View {
        Text(label)
            .font(badgeFont)
            .monospacedDigit()
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
        case .metra(let routeId): routeId
        case .amtrak(let routeId): AmtrakStationCatalog.route(id: routeId)?.displayCode ?? "ATK"
        }
    }

    private var accessibleLabel: String {
        switch kind {
        case .lLine(let line): line.displayName
        case .bus(let route): "Bus route \(route)"
        case .metra(let routeId):
            MetraStationCatalog.route(id: routeId)?.displayName ?? "Metra \(routeId)"
        case .amtrak(let routeId):
            AmtrakStationCatalog.route(id: routeId)?.displayName ?? "Amtrak \(routeId)"
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .lLine(let line): line.swiftUIColor
        case .bus: ChicagoPalette.Mode.bus
        case .metra(let routeId):
            MetraStationCatalog.route(id: routeId)?.swiftUIColor ?? ChicagoPalette.bahama
        case .amtrak(let routeId):
            AmtrakStationCatalog.route(id: routeId)?.swiftUIColor ?? ChicagoPalette.flagBlue
        }
    }

    private var textColor: Color {
        switch kind {
        case .lLine(let line): line.contrastingText
        case .bus: .white
        case .metra(let routeId):
            MetraStationCatalog.route(id: routeId)?.contrastingText ?? .white
        case .amtrak(let routeId):
            AmtrakStationCatalog.route(id: routeId)?.contrastingText ?? .white
        }
    }

    private var badgeFont: Font {
        ChicagoTypography.body(.bold, size: size.fontSize, relativeTo: size.fontStyle)
    }
}
