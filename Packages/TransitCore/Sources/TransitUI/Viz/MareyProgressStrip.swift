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
/// Caps the intermediate stop count at 10 to stay within the widget
/// render budget.
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
        self.intermediateStops = Array(intermediateStops.prefix(10))
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

                    // Tick labels — angled to stack without overlap
                    ForEach(intermediateStops, id: \.self) { tick in
                        let x = dotX + (geo.size.width - dotX) * tick.fraction
                        Text(tick.label)
                            .font(ChicagoTypography.displaySM(relativeTo: .caption2))
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .foregroundStyle(ChicagoPalette.Gray.dark)
                            .lineLimit(1)
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
                    .font(ChicagoTypography.displaySM(relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(0.5)
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
}
