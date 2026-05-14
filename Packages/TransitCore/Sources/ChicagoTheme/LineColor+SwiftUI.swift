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

    /// Text color that has reasonable contrast on this line color.
    var contrastingText: Color {
        switch self {
        case .yellow, .pink: .black
        default: .white
        }
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
