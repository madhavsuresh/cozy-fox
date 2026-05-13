import SwiftUI

/// A flat civic card: solid surface, hairline border, and an optional
/// eyebrow + title header set in Big Shoulders ALL CAPS — the same
/// rhythm a Chicago bulletin uses.
///
/// Replaces the ad-hoc `private struct Card` previously scattered
/// through the dashboard. Everything else flows from theme tokens, so
/// you only change padding/colours in one place.
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
                    .font(ChicagoTypography.displaySM())
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.bahama)
                    .accessibilityLabel(eyebrow)
            }
            if let title {
                HStack(spacing: ChicagoSpacing.sm) {
                    ornamentView
                    Text(title)
                        .font(ChicagoTypography.displayLG())
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .accessibilityLabel(title)
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
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        case .icon(let name):
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(ChicagoPalette.flagBlue)
                .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }
}
