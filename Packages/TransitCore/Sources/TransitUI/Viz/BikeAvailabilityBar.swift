import ChicagoTheme
import SwiftUI

/// A horizontal length-encoded gauge for Divvy dock availability. The
/// filled portion shows how many e-bikes are currently available; the
/// remainder shows empty docks. Capacity is communicated by **length**
/// — Cleveland & McGill rank length as the third most accurate visual
/// encoding (behind position) — so a glance answers "is this station
/// healthy, low, or empty?" without reading the number.
///
/// Colour reinforces but never replaces:
/// - `Mode.divvy` — healthy availability
/// - `gold`   — scarce (per `scarce` flag from upstream)
/// - `starRed` — empty
///
/// Caps tick rendering at 24 dock notches to keep widgets fast.
public struct BikeAvailabilityBar: View {
    private let current: Int
    private let capacity: Int
    private let scarce: Bool

    public init(current: Int, capacity: Int, scarce: Bool = false) {
        self.current = max(0, current)
        self.capacity = max(1, capacity)
        self.scarce = scarce
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            GeometryReader { geo in
                let fraction = Double(current) / Double(capacity)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ChicagoPalette.Gray.lighter)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(4, geo.size.width * fraction))
                    if capacity <= 24 {
                        // Hairline dock tick marks. Skip on big stations
                        // so the bar doesn't turn into a comb.
                        HStack(spacing: 0) {
                            ForEach(1..<capacity, id: \.self) { _ in
                                Spacer(minLength: 0)
                                Rectangle()
                                    .fill(ChicagoPalette.Surface.card.opacity(0.6))
                                    .frame(width: 0.5)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: ChicagoSpacing.xs) {
                Text("\(current) / \(capacity)")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.Gray.dark)
                Spacer()
                Text(statusLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(fillColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(current) of \(capacity) e-bikes available, \(statusLabel.lowercased())"
        )
    }

    private var fillColor: Color {
        if current == 0 { return ChicagoPalette.starRed }
        if scarce       { return ChicagoPalette.gold }
        return ChicagoPalette.Mode.divvy
    }

    private var statusLabel: String {
        if current == 0 { return "Empty" }
        if scarce       { return "Low" }
        return "OK"
    }
}
