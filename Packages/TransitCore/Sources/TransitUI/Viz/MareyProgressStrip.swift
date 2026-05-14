import ChicagoTheme
import SwiftUI

/// A vehicle's position along a route, drawn as a one-dimensional
/// **Marey-style** strip — Étienne-Jules Marey's 19th-century
/// time–distance diagram is still the gold standard for "where is the
/// train right now?" visualisations (Tufte, *The Visual Display of
/// Quantitative Information*, 1983, pp.110–115).
///
/// Layout:
/// ```
/// ●━━╿━━╿━━╿━━╿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★
/// Train                                    Belmont
/// ```
///
/// - Left dot: the vehicle (`vehicleLabel`).
/// - Vertical ticks: each intermediate stop, positioned geographically.
/// - **Right star**: the user's chosen stop. This is the only place in
///   the app where a `ChicagoStar` marks "this is where *you* are
///   going" — making the destination unmistakable.
///
/// Caps the intermediate stop count at 3 — more than that and the
/// rotated labels collide or fall off the strip. Tick label names are
/// auto-shortened (parentheticals dropped, "Square" → "Sq", etc.) so
/// they fit at 9pt without truncation.
public struct RouteStop: Hashable, Sendable {
    public let label: String
    /// 0…1, where 0 = at the vehicle, 1 = at the user's stop.
    public let fraction: Double
    public init(label: String, fraction: Double) {
        self.label = label
        self.fraction = fraction
    }
}

public struct MareyProgressStrip: View {
    public let distanceMeters: Double
    public let scaleMeters: Double
    public let accent: Color
    public let vehicleLabel: String
    public let stopLabel: String
    public let intermediateStops: [RouteStop]

    public init(
        distanceMeters: Double,
        scaleMeters: Double,
        accent: Color,
        vehicleLabel: String,
        stopLabel: String,
        intermediateStops: [RouteStop]
    ) {
        self.distanceMeters = distanceMeters
        self.scaleMeters = scaleMeters
        self.accent = accent
        self.vehicleLabel = vehicleLabel
        self.stopLabel = stopLabel
        self.intermediateStops = Array(intermediateStops.prefix(3))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            GeometryReader { geo in
                let clamped = min(max(distanceMeters, 0), scaleMeters)
                let progress = clamped / scaleMeters
                let dotX = geo.size.width * (1 - progress)

                ZStack(alignment: .topLeading) {
                    // Track
                    Capsule()
                        .fill(ChicagoPalette.Gray.lighter)
                        .frame(height: 3)
                        .position(x: geo.size.width / 2, y: 10)

                    // Intermediate stop ticks
                    ForEach(intermediateStops, id: \.self) { tick in
                        let x = dotX + (geo.size.width - dotX) * tick.fraction
                        Rectangle()
                            .fill(ChicagoPalette.Gray.dark)
                            .frame(width: 1.5, height: 8)
                            .position(x: x, y: 10)
                    }

                    // Vehicle dot (left-leading)
                    Circle()
                        .fill(accent)
                        .frame(width: 12, height: 12)
                        .position(x: min(max(6, dotX), geo.size.width - 6), y: 10)

                    // User's stop (right-trailing) — Chicago star
                    ChicagoStar()
                        .fill(ChicagoPalette.starRed)
                        .frame(width: 18, height: 18)
                        .position(x: geo.size.width - 9, y: 10)

                    // Tick labels — tiny Roboto, angled to stack without
                    // overlap, and pre-shortened so they don't run off
                    // the strip. We use Roboto here (not Big Shoulders)
                    // because tick labels are *axis labels*, not
                    // headings; small mixed-case reads better at 9pt
                    // than uppercase Big Shoulders.
                    ForEach(intermediateStops, id: \.self) { tick in
                        let x = dotX + (geo.size.width - dotX) * tick.fraction
                        Text(Self.shortenStopName(tick.label))
                            .font(ChicagoTypography.body(.medium,
                                                         size: 9,
                                                         relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .fixedSize()
                            .rotationEffect(.degrees(-30))
                            .position(x: x, y: 30)
                    }
                }
            }
            .frame(height: 48)

            HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
                Text(vehicleLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.dark)
                Text("·")
                    .foregroundStyle(ChicagoPalette.Gray.light)
                Text(formatDistance(distanceMeters))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                Spacer()
                Text(stopLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.starRed)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(vehicleLabel) is \(formatDistance(distanceMeters)) from \(stopLabel)"
        )
    }

    private func formatDistance(_ m: Double) -> String {
        if m < 1_000 { return "\(Int(m.rounded())) m" }
        return String(format: "%.1f km", m / 1_000)
    }

    /// Squeeze a CTA stop name down so it fits at 9pt without being
    /// truncated visually. Tuned for Chicago L / bus naming conventions:
    /// drops parentheticals (`"Western (Forest Park)"` → `"Western"`),
    /// drops slash-suffixes (`"California/Milwaukee"` → `"California"`),
    /// and applies the usual street-type abbreviations.
    static func shortenStopName(_ label: String) -> String {
        var s = label
        // Drop anything after "(" or "/" — Chicago L stops use these for
        // disambiguators that aren't needed when the line is implicit.
        if let idx = s.firstIndex(where: { $0 == "(" || $0 == "/" }) {
            s = String(s[..<idx])
        }
        s = s.trimmingCharacters(in: .whitespaces)

        let abbreviations: [(String, String)] = [
            (" Square", " Sq"),
            (" Park", " Pk"),
            (" Avenue", " Ave"),
            (" Boulevard", " Blvd"),
            (" Street", " St"),
            (" Place", " Pl"),
            (" Heights", " Hts"),
            (" Center", " Ctr"),
            (" Junction", " Jct"),
        ]
        for (long, short) in abbreviations {
            s = s.replacingOccurrences(of: long, with: short)
        }

        // Final hard cap. 9 chars is the most that fits at 9pt at -30°
        // rotation on the narrowest expected segment.
        if s.count > 9 {
            s = s.prefix(8).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s
    }
}
