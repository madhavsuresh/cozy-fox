import SwiftUI

/// A flat grouped surface: solid neutral fill, hairline border, and an
/// optional compact header. Route color carries wayfinding; this container
/// stays quiet.
public struct ChicagoCard<Content: View>: View {
    public enum Ornament: Sendable {
        case star
        case icon(systemName: String)
    }

    private let title: String?
    private let eyebrow: String?
    private let ornament: Ornament?
    private let content: () -> Content

    public init(
        title: String? = nil,
        eyebrow: String? = nil,
        ornament: Ornament? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.eyebrow = eyebrow
        self.ornament = ornament
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            if eyebrow != nil || title != nil {
                header
            }
            content()
        }
        .padding(ChicagoSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg)
                .strokeBorder(
                    ChicagoPalette.cornflower.opacity(0.35),
                    lineWidth: ChicagoSpacing.Stroke.hairline
                )
        )
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let eyebrow {
                Text(eyebrow)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.bahama)
                    .accessibilityLabel(eyebrow)
            }
            if let title {
                HStack(spacing: ChicagoSpacing.xs) {
                    ornamentView
                    Text(title)
                        .font(ChicagoTypography.body(.bold, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .accessibilityLabel(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    @ViewBuilder
    private var ornamentView: some View {
        switch ornament {
        case .star:
            ChicagoStar()
                .fill(ChicagoPalette.starRed)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        case .icon(let name):
            Image(systemName: name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ChicagoPalette.flagBlue)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }
}
