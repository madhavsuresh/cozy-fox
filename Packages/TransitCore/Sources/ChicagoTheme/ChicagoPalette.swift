import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    // MARK: - Transit modes

    /// Semantic accents for non-rail modes. These are intentionally outside
    /// the Chicago blue family so CTA Blue Line, buses, Intercampus, and
    /// Divvy are distinguishable at a glance.
    public enum Mode {
        /// CTA bus identity. A warm copper separates buses from CTA rail colors.
        public static let bus = adaptive(light: 0xA8481C, dark: 0xB85620)
        /// Northwestern Intercampus identity. Matches the shuttle's university context.
        public static let intercampus = adaptive(light: 0x4E2A84, dark: 0x7C3AED)
        /// Divvy / e-bike identity. Teal avoids CTA Blue while staying mobility-oriented.
        public static let divvy = adaptive(light: 0x007A5E, dark: 0x0B7A67)
    }

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

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            uiColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        srgb(light)
        #endif
    }

    private static func srgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    #if canImport(UIKit)
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
    #endif
}
