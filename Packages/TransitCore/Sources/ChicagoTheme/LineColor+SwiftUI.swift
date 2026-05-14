import Foundation
import SwiftUI
import TransitModels

public extension LineColor {
    var swiftUIColor: Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// Text color that keeps the CTA badge legible on the line color.
    var contrastingText: Color {
        textContrast(for: hex)
    }
}

public extension MetraLine {
    var swiftUIColor: Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    var contrastingText: Color {
        Color(
            red: Double((textHex >> 16) & 0xFF) / 255.0,
            green: Double((textHex >> 8) & 0xFF) / 255.0,
            blue: Double(textHex & 0xFF) / 255.0
        )
    }
}

private func textContrast(for hex: UInt32) -> Color {
    let whiteContrast = contrastRatio(foreground: 0xFFFFFF, background: hex)
    let blackContrast = contrastRatio(foreground: 0x000000, background: hex)
    return whiteContrast >= blackContrast ? .white : .black
}

private func contrastRatio(foreground: UInt32, background: UInt32) -> Double {
    let fg = relativeLuminance(foreground)
    let bg = relativeLuminance(background)
    let lighter = max(fg, bg)
    let darker = min(fg, bg)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ hex: UInt32) -> Double {
    let red = linearComponent(Double((hex >> 16) & 0xFF) / 255.0)
    let green = linearComponent(Double((hex >> 8) & 0xFF) / 255.0)
    let blue = linearComponent(Double(hex & 0xFF) / 255.0)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

private func linearComponent(_ value: Double) -> Double {
    value <= 0.03928
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
}
