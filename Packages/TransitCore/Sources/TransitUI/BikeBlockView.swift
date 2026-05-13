import SwiftUI
import TransitModels

public struct BikeBlockView: View {
    public let pick: NearestBikePick?

    public init(pick: NearestBikePick?) {
        self.pick = pick
    }

    public var body: some View {
        if let pick {
            content(for: pick)
        } else {
            empty
        }
    }

    private func content(for pick: NearestBikePick) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bicycle.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text(pick.station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("\(pick.walkingMinutes) min walk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "battery.100.bolt")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("×\(pick.station.eBikesAvailable)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if pick.bestRangeMeters > 0 {
                Text("\(Int(pick.bestRangeMiles.rounded())) mi best")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            if pick.station.isScarce {
                Label("Low (\(pick.station.eBikesAvailable))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "bicycle.circle")
                .foregroundStyle(.secondary)
            Text("No e-bikes nearby")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
