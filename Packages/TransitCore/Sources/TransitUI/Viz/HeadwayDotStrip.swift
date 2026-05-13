import ChicagoTheme
import SwiftUI

/// A row of dots laid out on a 0…`window` minute axis, one per upcoming
/// arrival. The pattern of dots reveals **bunching** at a glance: three
/// dots clustered to the left + a gap = bus bunching; evenly spaced
/// dots = healthy headways. Reading the text "4 · 6 · 8 · 19 min"
/// requires a sequential scan; this is parallel perception.
///
/// Cleveland & McGill (1984) ranked the visual encodings: **position on
/// a common scale** is the most accurate. That's exactly what a dot
/// strip encodes — each dot's x-position == minutes until arrival.
///
/// Imminent arrivals (≤3 min) are drawn slightly larger and at full
/// opacity. Later arrivals fade with distance from now. Past arrivals
/// (negative offsets) are clamped out.
///
/// Caps at 8 dots to respect the widget render budget.
public struct HeadwayDotStrip: View {
    private let arrivals: [Date]
    private let window: TimeInterval
    private let accent: Color
    private let now: Date

    public init(
        arrivals: [Date],
        window: TimeInterval = 30 * 60,
        accent: Color,
        now: Date = .now
    ) {
        self.arrivals = arrivals
        self.window = window
        self.accent = accent
        self.now = now
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                    .frame(width: geo.size.width)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                ForEach(Array(dotData.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(accent.opacity(dot.opacity))
                        .frame(width: dot.diameter, height: dot.diameter)
                        .position(
                            x: dot.fraction * geo.size.width,
                            y: geo.size.height / 2
                        )
                }
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleSummary)
    }

    // MARK: - Composition

    private var track: some View {
        Capsule()
            .fill(ChicagoPalette.Gray.lighter.opacity(0.6))
            .frame(height: 2)
    }

    private struct Dot {
        let fraction: Double
        let diameter: CGFloat
        let opacity: Double
    }

    private var dotData: [Dot] {
        arrivals
            .prefix(12)
            .compactMap { arrival -> Dot? in
                let delta = arrival.timeIntervalSince(now)
                guard delta >= 0, delta <= window else { return nil }
                let f = delta / window
                let minutes = delta / 60
                let imminent = minutes <= 3
                let diameter: CGFloat = imminent ? 12 : 8
                // Linear fade from 1.0 (now) to 0.55 (window edge), with
                // imminent dots locked at 1.0 for emphasis.
                let opacity = imminent ? 1.0 : (1.0 - (f * 0.45))
                return Dot(fraction: f, diameter: diameter, opacity: opacity)
            }
            .prefix(8)
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
