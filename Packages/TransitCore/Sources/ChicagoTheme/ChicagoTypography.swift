import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Typography roles backed by the Big Shoulders + Roboto pair from the
/// Chicago Design System.
///
/// - **Big Shoulders Display / Text** for headings, numbers, and labels.
///   Used in sentence case throughout the app — CDS recommends caps
///   for display, but in a phone UI all-caps reads as shouting. The
///   municipal typeface itself + the palette + the Chicago star carry
///   the civic identity without ALL-CAPS doing the heavy lifting.
/// - **Roboto** for body and UI copy.
///
/// All variants are returned as `Font` values built with
/// `.custom(_:size:relativeTo:)`, so Dynamic Type scaling Just Works.
/// Numeric variants (`bigNumber(_:)`) bake `.monospacedDigit()` in so
/// countdowns don't reflow when `9` ticks to `10`.
///
/// The bundled fonts are **variable** (single TTF with weight axis). On
/// iOS we build the font via `UIFontDescriptor` with the `wght` variation
/// axis, then bridge to SwiftUI `Font` through `UIFontMetrics` so
/// Dynamic Type scaling works automatically. On non-iOS platforms (the
/// package targets macOS too) we fall back to `Font.custom(_:size:)`
/// against the variable font's family name.
public enum ChicagoTypography {

    // MARK: - Display (Big Shoulders)

    /// Massive headline numbers — "4 MIN" arrival lockup.
    public static func displayXXL(relativeTo: Font.TextStyle = .largeTitle) -> Font {
        bigShouldersDisplay(size: 72, relativeTo: relativeTo)
    }
    /// Screen titles — "DASHBOARD", "SETTINGS".
    public static func displayXL(relativeTo: Font.TextStyle = .largeTitle) -> Font {
        bigShouldersDisplay(size: 48, relativeTo: relativeTo)
    }
    /// Card titles — "PIN AN L LINE".
    public static func displayLG(relativeTo: Font.TextStyle = .title) -> Font {
        bigShouldersDisplay(size: 28, relativeTo: relativeTo)
    }
    /// Section labels — "NEAR YOU", direction chips.
    public static func displayMD(relativeTo: Font.TextStyle = .title2) -> Font {
        bigShouldersDisplay(size: 20, relativeTo: relativeTo)
    }
    /// Eyebrow text, small chip labels.
    public static func displaySM(relativeTo: Font.TextStyle = .headline) -> Font {
        bigShouldersText(size: 15, relativeTo: relativeTo)
    }

    // MARK: - Body (Roboto)

    /// Body copy. Default is Regular at `.body`.
    public static func body(_ weight: BodyWeight = .regular,
                            size: CGFloat? = nil,
                            relativeTo: Font.TextStyle = .body) -> Font {
        roboto(weight: weight.rawValue,
               size: size ?? relativeTo.defaultSize,
               relativeTo: relativeTo)
    }

    public enum BodyWeight: CGFloat {
        case regular = 400
        case medium  = 500
        case bold    = 700
    }

    // MARK: - Big number (tabular)

    /// A massive countdown number rendered in Big Shoulders Display with
    /// **tabular numerals** — required so a 1-to-2-digit transition
    /// doesn't reflow the surrounding layout.
    public static func bigNumber(_ size: CGFloat,
                                 relativeTo: Font.TextStyle = .largeTitle) -> Font {
        bigShouldersDisplay(size: size, relativeTo: relativeTo).monospacedDigit()
    }

    // MARK: - Font builders (variable-font aware)

    private static func bigShouldersDisplay(size: CGFloat,
                                            relativeTo: Font.TextStyle) -> Font {
        variableFont(family: "BigShouldersDisplay",
                     weight: 700,
                     size: size,
                     relativeTo: relativeTo)
    }

    private static func bigShouldersText(size: CGFloat,
                                         relativeTo: Font.TextStyle) -> Font {
        variableFont(family: "BigShouldersText",
                     weight: 700,
                     size: size,
                     relativeTo: relativeTo)
    }

    private static func roboto(weight: CGFloat,
                               size: CGFloat,
                               relativeTo: Font.TextStyle) -> Font {
        variableFont(family: "Roboto",
                     weight: weight,
                     size: size,
                     relativeTo: relativeTo)
    }

    /// Build a `Font` from a registered variable font by specifying the
    /// weight via the OpenType `wght` variation axis.
    ///
    /// Falls back to the system font if the family isn't registered —
    /// which only happens if `ChicagoTheme.bootstrap()` wasn't called or
    /// the bundled resource is missing. Both conditions fail loudly in
    /// DEBUG via `assertionFailure` in `ChicagoTheme.registerFonts`.
    private static func variableFont(family: String,
                                     weight: CGFloat,
                                     size: CGFloat,
                                     relativeTo: Font.TextStyle) -> Font {
        #if canImport(UIKit)
        let baseDescriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            kVariationAttribute: [kWghtAxisTag: weight],
        ])
        let baseFont = UIFont(descriptor: baseDescriptor, size: size)
        let metrics = UIFontMetrics(forTextStyle: relativeTo.uiKitEquivalent)
        let scaled = metrics.scaledFont(for: baseFont)
        return Font(scaled)
        #else
        // On macOS the package compiles for completeness, but Big
        // Shoulders weight variants aren't selectable without UIKit's
        // descriptor — fall back to the variable font's family name and
        // let the system pick the default weight.
        return Font.custom(family, size: size, relativeTo: relativeTo)
        #endif
    }
}

#if canImport(UIKit)
// MARK: - Core Text variation key bridging
//
// `kCTFontVariationAttribute` and the wght axis tag (0x77676874 = 'wght')
// live in Core Text; expose them as `UIFontDescriptor.AttributeName` /
// `NSNumber` so we can pass them through the UIFontDescriptor attribute
// dictionary.

private let kVariationAttribute = UIFontDescriptor.AttributeName(
    rawValue: kCTFontVariationAttribute as String
)

/// 'wght' four-char code as an NSNumber, suitable for the variation dict.
private let kWghtAxisTag: NSNumber = NSNumber(value: 0x77676874 as UInt32)

private extension Font.TextStyle {
    /// Mirror in UIKit-land for `UIFontMetrics(forTextStyle:)`.
    var uiKitEquivalent: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title:      .title1
        case .title2:     .title2
        case .title3:     .title3
        case .headline:   .headline
        case .body:       .body
        case .callout:    .callout
        case .subheadline: .subheadline
        case .footnote:   .footnote
        case .caption:    .caption1
        case .caption2:   .caption2
        @unknown default: .body
        }
    }
}
#endif

private extension Font.TextStyle {
    /// Default point size at the default Dynamic Type size (`.large`).
    /// Used as the "rest" size when callers don't specify one.
    var defaultSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title:      28
        case .title2:     22
        case .title3:     20
        case .headline:   17
        case .body:       17
        case .callout:    16
        case .subheadline: 15
        case .footnote:   13
        case .caption:    12
        case .caption2:   11
        @unknown default: 17
        }
    }
}
