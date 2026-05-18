import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels
#if canImport(UIKit)
import UIKit
#endif

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
        /// Strongest positive marker: every signal the scorer has lines
        /// up. Renders as a saturated green checkmark, dot keeps full
        /// route accent.
        case confirmed
        /// Weaker positive marker: we have a tracked vehicle but at
        /// least one signal is soft (mediumConfidence). Renders as a
        /// muted-green checkmark, dot keeps full route accent — the
        /// glyph carries the step down, the dot stays trustworthy.
        case tracked
        /// Soft uncertainty: we don't have enough evidence to call
        /// this confirmed. Gold `?` badge, dot fades partly toward
        /// neutral.
        case unconfirmed
        /// Strong uncertainty: matches Google Maps' "scheduled only"
        /// red flag. Red `!` badge, dot fades hard toward neutral so
        /// the eye reads "don't plan on this."
        case likelyGhost
        /// Stronger than `.likelyGhost`: we have evidence this row is
        /// positively wrong (CTA's `dyn` flagged it, the stop is on a
        /// removed-by-detour list, the vehicle's already crossed the
        /// stop, etc.). Renders as a red `X` — distinct glyph from
        /// `likelyGhost`'s `!` — with the dot flattened to neutral
        /// entirely. Surfaces only when the user has set the
        /// bus-prediction filter level to "Show everything";
        /// `inclusive` (default) and stricter levels filter these out
        /// before the strip sees them.
        case cancelled
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
    /// and the bucket is `.missed`, the dot grays out so the eye stops
    /// reading it as active service. Other buckets (`.approaching`,
    /// `.imminent`) intentionally do **not** paint extra color over
    /// the dot — the strip already encodes urgency through position
    /// (left edge = sooner) and through the imminent size bump, so a
    /// red glow would be a third overlapping signal that competes
    /// with the reliability ladder for the same red hue. Glance
    /// affordance: hue = trust, position+size = urgency.
    private let urgencies: [DepartureUrgency.Bucket?]
    /// Optional per-arrival confidence tones. When present and non-nil
    /// for a dot, `.weak` mutes the dot to ~60% of its computed opacity
    /// (the arrival's bias history or live flags suggest it's less
    /// trustworthy than the headline number). `.strong` leaves the dot
    /// alone — the strip already emphasizes imminent dots, so we don't
    /// double-emphasize confidence. Nonverbal by design.
    private let confidenceTones: [ArrivalConfidenceMark.Tone?]

    public init(
        arrivals: [Date],
        window: TimeInterval = 30 * 60,
        accent: Color,
        now: Date = .now,
        complications: [Complication?] = [],
        urgencies: [DepartureUrgency.Bucket?] = [],
        confidenceTones: [ArrivalConfidenceMark.Tone?] = [],
        style: Style = .standard
    ) {
        self.arrivals = arrivals
        self.window = window
        self.accent = accent
        self.now = now
        self.style = style
        self.complications = complications
        self.urgencies = urgencies
        self.confidenceTones = confidenceTones
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
        let confidence: ArrivalConfidenceMark.Tone?
    }

    @ViewBuilder
    private func dotView(_ dot: Dot) -> some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(dotFill(dot))
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
                let baseOpacity = imminent ? 1.0 : (1.0 - (fraction * 0.45))
                let tone = confidence(at: index)
                let opacity = baseOpacity * confidenceOpacityMultiplier(tone)
                return Dot(fraction: fraction,
                           diameter: diameter,
                           opacity: opacity,
                           minutes: minutes,
                           complication: complication(at: index),
                           urgency: urgency(at: index),
                           confidence: tone)
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

    private func confidence(at index: Int) -> ArrivalConfidenceMark.Tone? {
        guard index < confidenceTones.count else { return nil }
        return confidenceTones[index]
    }

    /// `.weak` mutes the dot to ~60% of its computed opacity so an
    /// unreliable arrival reads as quieter than its neighbors without
    /// disappearing. `.strong` and `.normal` (and absent tones) leave
    /// the dot at full strength — the strip already emphasizes imminent
    /// arrivals, so layering on top would double-encode.
    private func confidenceOpacityMultiplier(_ tone: ArrivalConfidenceMark.Tone?) -> Double {
        switch tone {
        case .weak:                return 0.6
        case .strong, .normal, nil: return 1.0
        }
    }

    /// Base fill for a dot. Two axes layer:
    ///
    /// 1. `.missed` urgency wins outright — those dots flatten to a
    ///    medium neutral so the eye reads "this one is gone" without
    ///    assuming the accent color means it's still active.
    /// 2. Otherwise, the dot's *complication* (reliability) decides
    ///    how much route accent survives. Confirmed/tracked dots
    ///    render at full accent; unconfirmed/ghost/cancelled dots
    ///    blend toward the neutral so untrustworthy arrivals visually
    ///    fade — the badge glyph above them carries the verdict, the
    ///    fade reinforces it. This is the single "hue = trust" rule
    ///    the strip is meant to read by.
    private func dotFill(_ dot: Dot) -> Color {
        if dot.urgency == .missed {
            switch style {
            case .standard: return ChicagoPalette.Gray.medium.opacity(dot.opacity * 0.45)
            case .onDark:   return ChicagoPalette.OnDarkSafe.tertiary.opacity(dot.opacity * 0.55)
            }
        }
        let blend = trustBlend(dot.complication)
        if blend >= 0.999 {
            return accent.opacity(dot.opacity)
        }
        let neutral = trustNeutral
        return blendedColor(accent: accent, neutral: neutral, accentShare: blend)
            .opacity(dot.opacity)
    }

    private func trustBlend(_ complication: Complication?) -> Double {
        HeadwayDotStrip.trustBlend(for: complication)
    }

    /// How much of the route accent survives at a given complication.
    /// 1.0 = full accent. 0.0 = pure neutral. The ladder is meant to
    /// be visually monotonic so a glance can read "more saturated =
    /// more trustworthy" without parsing the glyph. `internal` so
    /// `TransitUITests` can assert the ladder doesn't accidentally
    /// regress as we tune values.
    static func trustBlend(for complication: Complication?) -> Double {
        switch complication {
        case nil, .confirmed, .tracked: return 1.0
        case .unconfirmed:              return 0.55
        case .likelyGhost:              return 0.30
        case .cancelled:                return 0.0
        }
    }

    /// The neutral the accent fades toward when trust drops. Picked
    /// per-style so the dot remains legible on both light cards and
    /// the system-imposed dark of the Live Activity chrome.
    private var trustNeutral: Color {
        switch style {
        case .standard: return ChicagoPalette.Gray.medium
        case .onDark:   return ChicagoPalette.OnDarkSafe.tertiary
        }
    }

    /// Lerp two SwiftUI colors in sRGB via UIKit. SwiftUI has no
    /// first-class blending primitive, and a `ZStack` of two `.fill`s
    /// at varying opacity would also tint the underlying surface — we
    /// want a fully-opaque blended hue so the dot stays crisp when
    /// `dot.opacity` later modulates the whole thing.
    private func blendedColor(accent: Color, neutral: Color, accentShare: Double) -> Color {
        let share = max(0.0, min(1.0, accentShare))
        #if canImport(UIKit)
        let accentRGBA = UIColor(accent).rgbaComponents
        let neutralRGBA = UIColor(neutral).rgbaComponents
        return Color(
            red:   accentRGBA.r * share + neutralRGBA.r * (1 - share),
            green: accentRGBA.g * share + neutralRGBA.g * (1 - share),
            blue:  accentRGBA.b * share + neutralRGBA.b * (1 - share),
            opacity: accentRGBA.a * share + neutralRGBA.a * (1 - share)
        )
        #else
        // macOS is preview/test-only for this package; fade the accent
        // toward transparency as a close-enough stand-in.
        return accent.opacity(share)
        #endif
    }

    private func complicationSymbol(_ complication: Complication) -> String {
        HeadwayDotStrip.glyphSymbol(for: complication)
    }

    /// SF Symbol that sits on top of each complication badge. Exposed
    /// as `internal static` so tests can verify the bus/train modes
    /// agree on the glyph vocabulary without a snapshot harness.
    static func glyphSymbol(for complication: Complication) -> String {
        switch complication {
        case .confirmed:   "checkmark"
        case .tracked:     "checkmark"
        case .unconfirmed: "questionmark"
        case .likelyGhost: "exclamationmark"
        case .cancelled:   "xmark"
        }
    }

    private func complicationColor(_ complication: Complication) -> Color {
        switch complication {
        case .confirmed:
            ChicagoPalette.green
        case .tracked:
            // Same hue as `.confirmed` but desaturated so a glance
            // reads the ladder confirmed → tracked → unconfirmed
            // without parsing the glyph.
            ChicagoPalette.green.opacity(0.55)
        case .unconfirmed:
            ChicagoPalette.gold
        case .likelyGhost:
            ChicagoPalette.starRed
        case .cancelled:
            // Same hue as likelyGhost so the family reads as
            // "warning" at a glance; the `X` glyph (vs `!`) escalates
            // to "positively wrong."
            ChicagoPalette.starRed
        }
    }

    private func complicationForeground(_ complication: Complication) -> Color {
        HeadwayDotStrip.glyphUsesLightForeground(for: complication) ? .white : .black
    }

    /// Whether the glyph should render in white (true) or black
    /// (false) on its complication badge. Hardcoded for stable WCAG
    /// contrast across light/dark mode: gold is the one badge color
    /// where black wins (`Gray.darkest` flips to near-white in dark
    /// mode and loses contrast against CDS gold), white wins on the
    /// green/red badges in either mode. Exposed as `internal static`
    /// so tests can verify the contrast story without a render
    /// harness.
    static func glyphUsesLightForeground(for complication: Complication) -> Bool {
        switch complication {
        case .unconfirmed:                                 false
        case .confirmed, .tracked, .likelyGhost, .cancelled: true
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

#if canImport(UIKit)
private extension UIColor {
    /// sRGB components of a resolved UIColor. Used to lerp two
    /// SwiftUI `Color`s into a single opaque blended hue. Resolution
    /// happens with `traitCollection.current`, so dark-mode variants
    /// of asset-catalog colors are picked up correctly when the dot
    /// strip is rendered in dark surfaces.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = self.resolvedColor(with: .current)
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
#endif
