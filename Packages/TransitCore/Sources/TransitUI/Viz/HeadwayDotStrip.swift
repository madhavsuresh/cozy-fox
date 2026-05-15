import ChicagoTheme
import SwiftUI
import TransitDomain

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
    public enum Complication: Sendable, Hashable {
        case unconfirmed
        case likelyGhost
        case stale
    }

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
    private let complications: [Complication?]
    /// Optional per-arrival "departure urgency" buckets. When present
    /// and the bucket is non-nil for a dot, the dot picks up a very
    /// subtle warm overlay (`.approaching` / `.imminent`) or grays out
    /// (`.missed`). When the array is shorter than the arrival list
    /// or the value is nil, the dot renders with the legacy neutral
    /// style. Tints are intentionally faint — passive readout, not a
    /// nudge.
    private let urgencies: [DepartureUrgency.Bucket?]

    public init(
        arrivals: [Date],
        window: TimeInterval = 30 * 60,
        accent: Color,
        now: Date = .now,
        complications: [Complication?] = [],
        urgencies: [DepartureUrgency.Bucket?] = [],
        style: Style = .standard
    ) {
        self.arrivals = arrivals
        self.window = window
        self.accent = accent
        self.now = now
        self.style = style
        self.complications = complications
        self.urgencies = urgencies
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

                // Minute labels for the first three arrivals. When two
                // arrivals fall close enough in time that their labels
                // would visually collide (e.g. trains at 1 and 2 min in a
                // half-width column), keep only the soonest — that's the
                // informationally critical one, and the dots themselves
                // still convey the cluster.
                ForEach(Array(visibleLabels(in: geo.size.width).enumerated()),
                        id: \.offset) { _, dot in
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
                    dotView(dot)
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
        let complication: Complication?
        let urgency: DepartureUrgency.Bucket?
    }

    @ViewBuilder
    private func dotView(_ dot: Dot) -> some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(dotFill(dot))
                .overlay {
                    if let urgencyAlpha = urgencyOverlayAlpha(dot.urgency) {
                        Circle()
                            .fill(urgencyOverlayColor.opacity(urgencyAlpha))
                    }
                }
                .overlay {
                    if let complication = dot.complication {
                        Circle()
                            .stroke(complicationColor(complication), lineWidth: 1.5)
                    }
                }
            if let complication = dot.complication {
                Image(systemName: complicationSymbol(complication))
                    .font(.system(size: dot.diameter <= 8 ? 5 : 6, weight: .black))
                    .foregroundStyle(complicationForeground(complication))
                    .frame(width: 8, height: 8)
                    .background(complicationColor(complication), in: Circle())
                    .offset(x: 4, y: -4)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Greedy left-to-right pass over the first three dots: keep each
    /// label only if it sits at least `minLabelGap` pt to the right of
    /// the previously kept one. Iterating in arrival order means we
    /// always keep the soonest of any colliding pair.
    private func visibleLabels(in width: CGFloat) -> [Dot] {
        let minLabelGap: CGFloat = 20  // ≈ widest 2-digit label + breathing
        var lastX: CGFloat = -.infinity
        var kept: [Dot] = []
        for dot in dotData.prefix(3) {
            let x = dot.fraction * width
            if x - lastX >= minLabelGap {
                kept.append(dot)
                lastX = x
            }
        }
        return kept
    }

    private var dotData: [Dot] {
        arrivals
            .prefix(10)
            .enumerated()
            .compactMap { index, arrival -> Dot? in
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
                           minutes: minutes,
                           complication: complication(at: index),
                           urgency: urgency(at: index))
            }
            .prefix(6)
            .map { $0 }
    }

    private func complication(at index: Int) -> Complication? {
        guard index < complications.count else { return nil }
        return complications[index]
    }

    private func urgency(at index: Int) -> DepartureUrgency.Bucket? {
        guard index < urgencies.count else { return nil }
        return urgencies[index]
    }

    /// Base fill for a dot. `.missed` dots desaturate to neutral so
    /// they read as "this one is gone" without the eye assuming the
    /// accent color means it's still active.
    private func dotFill(_ dot: Dot) -> Color {
        switch dot.urgency {
        case .missed:
            switch style {
            case .standard: return ChicagoPalette.Gray.medium.opacity(dot.opacity * 0.45)
            case .onDark:   return ChicagoPalette.OnDarkSafe.tertiary.opacity(dot.opacity * 0.55)
            }
        case .comfortable, .approaching, .imminent, .none:
            return accent.opacity(dot.opacity)
        }
    }

    /// Faint warm overlay alpha for the approaching/imminent buckets.
    /// Returns nil for `.comfortable`, `.missed`, and absent urgencies
    /// — those don't paint anything over the base fill.
    private func urgencyOverlayAlpha(_ bucket: DepartureUrgency.Bucket?) -> Double? {
        switch bucket {
        case .approaching: return 0.14
        case .imminent:    return 0.28
        case .comfortable, .missed, .none: return nil
        }
    }

    /// Warm overlay color — same hue across both styles, alpha-blended
    /// onto whatever accent the dot already has.
    private var urgencyOverlayColor: Color {
        ChicagoPalette.starRed
    }

    private func complicationSymbol(_ complication: Complication) -> String {
        switch complication {
        case .unconfirmed: "questionmark"
        case .likelyGhost: "exclamationmark"
        case .stale: "clock"
        }
    }

    private func complicationColor(_ complication: Complication) -> Color {
        switch (style, complication) {
        case (_, .likelyGhost):
            ChicagoPalette.starRed
        case (_, .unconfirmed):
            ChicagoPalette.gold
        case (.standard, .stale):
            ChicagoPalette.Gray.medium
        case (.onDark, .stale):
            ChicagoPalette.OnDarkSafe.tertiary
        }
    }

    private func complicationForeground(_ complication: Complication) -> Color {
        switch complication {
        case .unconfirmed:
            ChicagoPalette.Gray.darkest
        case .likelyGhost, .stale:
            .white
        }
    }

    private var accessibleSummary: String {
        let minutes = arrivals
            .prefix(4)
            .map { Int(($0.timeIntervalSince(now) / 60).rounded()) }
            .filter { $0 >= 0 }
        if minutes.isEmpty { return "No upcoming arrivals" }
        let list = minutes.map(String.init).joined(separator: ", ")
        let flagged = complications.prefix(4).compactMap { $0 }.count
        if flagged > 0 {
            return "Upcoming arrivals at \(list) minutes, with \(flagged) unverified"
        }
        return "Upcoming arrivals at \(list) minutes"
    }
}
