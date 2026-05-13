import ChicagoTheme
import SwiftUI

/// A row of dots laid out on a 0…`window` minute axis, one per upcoming
/// arrival. The first three dots are labelled with their minute value,
/// so the strip is self-documenting: you read the three labels for the
/// next three arrivals, and the unlabeled dots beyond them reveal the
/// broader pattern — three clustered + a gap means bunching, evenly
/// spaced means healthy headways. Reading the text "4 · 6 · 8 · 19 min"
/// is sequential; this is parallel perception.
///
/// Cleveland & McGill (1984) ranked visual encodings: position on a
/// common scale is the most accurate. Each dot's x-position == minutes
/// until arrival.
///
/// Imminent arrivals (≤3 min) are drawn slightly larger and at full
/// opacity. Later arrivals fade with distance. Past arrivals are
/// clamped out. Caps at 6 dots to keep the strip from feeling busy.
public struct HeadwayDotStrip: View {
    public enum Style: Sendable {
        /// Standard surface — light card or dashboard background.
        case standard
        /// Lock-screen / Live Activity / Dynamic Island. The asset-catalog
        /// gray ramp can't be trusted here (the chrome is system-imposed
        /// dark, not always reflected in `colorScheme`), so the strip
        /// switches to explicit dark-safe colors.
        case onDark
    }

    private let arrivals: [Date]
    private let window: TimeInterval
    private let accent: Color
    private let now: Date
    private let style: Style

    public init(
        arrivals: [Date],
        window: TimeInterval = 30 * 60,
        accent: Color,
        now: Date = .now,
        style: Style = .standard
    ) {
        self.arrivals = arrivals
        self.window = window
        self.accent = accent
        self.now = now
        self.style = style
    }

    private var trackColor: Color {
        switch style {
        case .standard: ChicagoPalette.Gray.lighter.opacity(0.6)
        case .onDark:   Color.white.opacity(0.20)
        }
    }
    private var labelColor: Color {
        switch style {
        case .standard: ChicagoPalette.Gray.darkest
        case .onDark:   ChicagoPalette.OnDarkSafe.primary
        }
    }
    private var axisColor: Color {
        switch style {
        case .standard: ChicagoPalette.Gray.light
        case .onDark:   ChicagoPalette.OnDarkSafe.tertiary
        }
    }

    public var body: some View {
        GeometryReader { geo in
            let trackY: CGFloat = 22
            let labelY: CGFloat = 8
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(trackColor)
                    .frame(height: 2)
                    .position(x: geo.size.width / 2, y: trackY)

                // Minute labels for the first three arrivals
                ForEach(Array(dotData.prefix(3).enumerated()), id: \.offset) { _, dot in
                    Text("\(dot.minutes)")
                        .font(ChicagoTypography.body(.medium,
                                                     size: 11,
                                                     relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(labelColor)
                        .position(x: dot.fraction * geo.size.width, y: labelY)
                }

                // Dots on the track
                ForEach(Array(dotData.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(accent.opacity(dot.opacity))
                        .frame(width: dot.diameter, height: dot.diameter)
                        .position(x: dot.fraction * geo.size.width, y: trackY)
                }

                // Right-edge axis caption — quietly anchors the scale.
                Text("\(Int(window / 60)) min")
                    .font(ChicagoTypography.body(.regular,
                                                 size: 9,
                                                 relativeTo: .caption2))
                    .foregroundStyle(axisColor)
                    .position(x: geo.size.width - 18, y: 34)
            }
        }
        .frame(height: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleSummary)
    }

    // MARK: - Composition

    private struct Dot {
        let fraction: Double
        let diameter: CGFloat
        let opacity: Double
        let minutes: Int
    }

    private var dotData: [Dot] {
        arrivals
            .prefix(10)
            .compactMap { arrival -> Dot? in
                let delta = arrival.timeIntervalSince(now)
                guard delta >= 0, delta <= window else { return nil }
                let fraction = delta / window
                let minutes = Int((delta / 60).rounded())
                let imminent = delta <= 3 * 60
                let diameter: CGFloat = imminent ? 12 : 8
                // Linear fade from 1.0 (now) to 0.55 (window edge); imminent
                // dots locked at 1.0 for emphasis.
                let opacity = imminent ? 1.0 : (1.0 - (fraction * 0.45))
                return Dot(fraction: fraction,
                           diameter: diameter,
                           opacity: opacity,
                           minutes: minutes)
            }
            .prefix(6)
            .map { $0 }
    }

    private var accessibleSummary: String {
        let minutes = arrivals
            .prefix(4)
            .map { Int(($0.timeIntervalSince(now) / 60).rounded()) }
            .filter { $0 >= 0 }
        if minutes.isEmpty { return "No upcoming arrivals" }
        let list = minutes.map(String.init).joined(separator: ", ")
        return "Upcoming arrivals at \(list) minutes"
    }
}
