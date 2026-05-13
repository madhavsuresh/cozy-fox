import SwiftUI

/// City of Chicago Design System palette, mapped to SwiftUI `Color`s with
/// Dark Mode variants resolved from the bundled asset catalog.
///
/// Source: design.chicago.gov. Light values are CDS as-published. Dark
/// variants are tuned: the official palette wasn't designed for dark
/// surfaces, so accents are brightened slightly to retain identity, and
/// deep blues are flipped to lighter blues. Surfaces (`Surface.*`)
/// intentionally bind to UIKit's system-grouped colors so app chrome
/// (nav bars, tab bars) stays in agreement with our content.
public enum ChicagoPalette {
    // MARK: - Primary

    /// The unmistakable Chicago sky-blue from the flag's bands. App tint.
    public static let flagBlue = catalog("flagBlue")
    /// The four-pointed star's red. Use for alerts, errors, and the star
    /// itself — *never* as a passive accent.
    public static let starRed  = catalog("starRed")

    // MARK: - Secondary blues

    public static let bahama       = catalog("bahama")
    public static let lochmara     = catalog("lochmara")
    public static let cornflower   = catalog("cornflower")
    public static let lakeMichigan = catalog("lakeMichigan")

    // MARK: - Accents

    public static let gold  = catalog("gold")
    public static let green = catalog("green")

    // MARK: - Grays (semantic name, not visual lightness — `darkest` is darkest in light mode and lightest in dark mode)

    public enum Gray {
        public static let darkest  = catalog("grayDarkest")
        public static let dark     = catalog("grayDark")
        public static let medium   = catalog("grayMedium")
        public static let light    = catalog("grayLight")
        public static let lighter  = catalog("grayLighter")
        public static let lightest = catalog("grayLightest")
    }

    // MARK: - State

    public static let focus = catalog("focus")

    // MARK: - Surfaces (bound to UIKit semantics for chrome agreement)

    public enum Surface {
        #if canImport(UIKit)
        public static let background = Color(uiColor: .systemGroupedBackground)
        public static let card       = Color(uiColor: .secondarySystemGroupedBackground)
        public static let elevated   = Color(uiColor: .tertiarySystemGroupedBackground)
        #else
        // macOS fallbacks — the package compiles for completeness but the
        // app is iOS-only. Use grayscale neutrals that approximate the
        // iOS-grouped surfaces.
        public static let background = ChicagoPalette.Gray.lightest
        public static let card       = Color.white
        public static let elevated   = Color.white
        #endif
    }

    // MARK: - Lock-screen-safe accents (Live Activity + lock widgets)
    //
    // The Live Activity renders on a system-chosen dark background. Only
    // colors with ≥4.5:1 contrast against near-black belong here. Bahama
    // (#005B99) disappears against the dark chrome; it's intentionally
    // not exposed here.

    public enum OnDarkSafe {
        public static let flagBlue = ChicagoPalette.flagBlue
        public static let starRed  = ChicagoPalette.starRed
        public static let gold     = ChicagoPalette.gold
        public static let green    = ChicagoPalette.green
        public static let primary  = Color.white
        public static let secondary = Color.white.opacity(0.70)
        public static let tertiary  = Color.white.opacity(0.50)
    }

    // MARK: - Helper

    private static func catalog(_ name: String) -> Color {
        Color(name, bundle: .module)
    }
}
