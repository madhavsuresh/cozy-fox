#if DEBUG
import SwiftUI

/// A visual catalog exercising every Chicago Design System token —
/// colours, typography, the star, badges, the card. Keep this preview
/// healthy: it is the single source of truth for "what does our theme
/// look like" and the fastest way to spot a regression when tweaking
/// tokens. Render it in **both** light and dark mode after every
/// palette change.
struct ChicagoThemeCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChicagoSpacing.lg) {
                section("Display typography (Big Shoulders)") {
                    Text("Display XXL").font(ChicagoTypography.displayXXL())
                        .textCase(.uppercase).tracking(1)
                    Text("Display XL").font(ChicagoTypography.displayXL())
                        .textCase(.uppercase).tracking(1)
                    Text("Display LG").font(ChicagoTypography.displayLG())
                        .textCase(.uppercase).tracking(0.5)
                    Text("Display MD").font(ChicagoTypography.displayMD())
                        .textCase(.uppercase).tracking(0.5)
                    Text("Display SM").font(ChicagoTypography.displaySM())
                        .textCase(.uppercase).tracking(0.5)
                }
                section("Body typography (Roboto)") {
                    Text("Roboto Regular — the quick brown fox jumps over the lazy dog.")
                        .font(ChicagoTypography.body())
                    Text("Roboto Medium — the quick brown fox jumps over the lazy dog.")
                        .font(ChicagoTypography.body(.medium))
                    Text("Roboto Bold — the quick brown fox jumps over the lazy dog.")
                        .font(ChicagoTypography.body(.bold))
                }
                section("BigNumber lockup") {
                    HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.md) {
                        ChicagoTheme_BigNumberSample(value: 4)
                        ChicagoTheme_BigNumberSample(value: 12)
                        ChicagoTheme_BigNumberSample(value: 22)
                    }
                }
                section("Colors") {
                    swatchGrid
                }
                section("Chicago star") {
                    HStack(spacing: ChicagoSpacing.md) {
                        ChicagoStar()
                            .fill(ChicagoPalette.starRed)
                            .frame(width: 24, height: 24)
                        ChicagoStar()
                            .fill(ChicagoPalette.starRed)
                            .frame(width: 48, height: 48)
                        ChicagoStar()
                            .fill(ChicagoPalette.starRed)
                            .frame(width: 96, height: 96)
                    }
                }
                section("Card") {
                    ChicagoCard(title: "Pin an L line",
                                eyebrow: "Trains",
                                ornament: .icon(systemName: "tram.fill")) {
                        Text("Pinned card with a header eyebrow + title and a body slot.")
                            .font(ChicagoTypography.body())
                    }
                    ChicagoCard(title: "Service alerts",
                                eyebrow: "Heads up",
                                ornament: .star) {
                        Text("Star-ornamented variant for alerts.")
                            .font(ChicagoTypography.body())
                    }
                }
            }
            .padding(ChicagoSpacing.md)
        }
        .background(ChicagoPalette.Surface.background)
    }

    private var swatchGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: ChicagoSpacing.xs), count: 4)
        return LazyVGrid(columns: columns, spacing: ChicagoSpacing.sm) {
            swatch("Flag Blue", ChicagoPalette.flagBlue)
            swatch("Star Red", ChicagoPalette.starRed)
            swatch("Bahama", ChicagoPalette.bahama)
            swatch("Lochmara", ChicagoPalette.lochmara)
            swatch("Cornflower", ChicagoPalette.cornflower)
            swatch("Lake Mich.", ChicagoPalette.lakeMichigan)
            swatch("Gold", ChicagoPalette.gold)
            swatch("Green", ChicagoPalette.green)
            swatch("Gray Darkest", ChicagoPalette.Gray.darkest)
            swatch("Gray Dark", ChicagoPalette.Gray.dark)
            swatch("Gray Medium", ChicagoPalette.Gray.medium)
            swatch("Gray Light", ChicagoPalette.Gray.light)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: ChicagoSpacing.xs) {
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
                .fill(color)
                .frame(height: 44)
            Text(name)
                .font(ChicagoTypography.displaySM(relativeTo: .caption2))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(ChicagoPalette.Gray.darkest)
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            Text(title)
                .font(ChicagoTypography.displayMD())
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(ChicagoPalette.bahama)
            content()
        }
    }
}

/// Bare-minimum BigNumber wrapper for the catalog (BigNumber is in the
/// same module so we don't expose it via a separate test target).
private struct ChicagoTheme_BigNumberSample: View {
    let value: Int
    var body: some View {
        BigNumber(value, unit: "min", size: .md)
    }
}

#Preview("Catalog — Light") {
    ChicagoThemeCatalog().preferredColorScheme(.light)
}

#Preview("Catalog — Dark") {
    ChicagoThemeCatalog().preferredColorScheme(.dark)
}
#endif
