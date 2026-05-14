import ChicagoTheme
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
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                Image(systemName: "bicycle")
                    .font(.caption)
                    .foregroundStyle(ChicagoPalette.Mode.divvy)
                Text(pick.station.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            BigNumber(
                pick.walkingMinutes,
                unit: "min walk",
                size: .md,
                tone: pick.station.isScarce ? .warning : .primary,
                accessibilityLabel: "\(pick.walkingMinutes) minute walk to e-bikes"
            )
            BikeAvailabilityBar(
                current: pick.station.eBikesAvailable,
                capacity: max(1, pick.station.capacity),
                scarce: pick.station.isScarce
            )
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            Image(systemName: "bicycle")
                .foregroundStyle(ChicagoPalette.Gray.light)
            Text("No e-bikes nearby")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
