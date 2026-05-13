import Foundation

public enum LineColor: String, Codable, Sendable, CaseIterable, Hashable {
    case red
    case blue
    case brown
    case green
    case orange
    case purple
    case pink
    case yellow

    public init?(ctaRouteCode code: String) {
        switch code.uppercased() {
        case "RED": self = .red
        case "BLUE": self = .blue
        case "BRN": self = .brown
        case "G": self = .green
        case "ORG": self = .orange
        case "P", "PEXP": self = .purple
        case "PINK": self = .pink
        case "Y": self = .yellow
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .red: "Red Line"
        case .blue: "Blue Line"
        case .brown: "Brown Line"
        case .green: "Green Line"
        case .orange: "Orange Line"
        case .purple: "Purple Line"
        case .pink: "Pink Line"
        case .yellow: "Yellow Line"
        }
    }

    public var shortName: String {
        switch self {
        case .red: "Red"
        case .blue: "Blue"
        case .brown: "Brn"
        case .green: "Grn"
        case .orange: "Org"
        case .purple: "Prp"
        case .pink: "Pnk"
        case .yellow: "Yel"
        }
    }

    /// CTA's hex brand colors.
    public var hex: UInt32 {
        switch self {
        case .red: 0xC60C30
        case .blue: 0x00A1DE
        case .brown: 0x62361B
        case .green: 0x009B3A
        case .orange: 0xF9461C
        case .purple: 0x522398
        case .pink: 0xE27EA6
        case .yellow: 0xF9E300
        }
    }
}
