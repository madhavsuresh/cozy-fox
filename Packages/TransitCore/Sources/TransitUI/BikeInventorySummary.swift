import ChicagoTheme
import SwiftUI
import TransitModels

public struct BikeInventorySummary: View {
    public let dockedCount: Int
    public let chargeSummary: EBikeChargeSummary?
    public let scarce: Bool

    public init(
        dockedCount: Int,
        chargeSummary: EBikeChargeSummary?,
        scarce: Bool
    ) {
        self.dockedCount = dockedCount
        self.chargeSummary = chargeSummary
        self.scarce = scarce
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: ChicagoSpacing.xs) {
            BigNumber(
                dockedCount,
                unit: "docked",
                size: .sm,
                tone: scarce ? .warning : .accent,
                accessibilityLabel: "\(dockedCount) docked e-bike\(dockedCount == 1 ? "" : "s") available"
            )
            if let chargeSummary {
                Text(chargeText(for: chargeSummary))
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.green)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(accessibilityChargeText(for: chargeSummary))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chargeText(for chargeSummary: EBikeChargeSummary) -> String {
        switch chargeSummary.count {
        case 1:
            return "\(miles(chargeSummary.minRangeMeters)) mi charge"
        case 2:
            return "low/high \(miles(chargeSummary.minRangeMeters))/\(miles(chargeSummary.maxRangeMeters)) mi"
        default:
            return "low \(miles(chargeSummary.minRangeMeters)) · med \(miles(chargeSummary.medianRangeMeters)) · high \(miles(chargeSummary.maxRangeMeters)) mi"
        }
    }

    private func accessibilityChargeText(for chargeSummary: EBikeChargeSummary) -> String {
        switch chargeSummary.count {
        case 1:
            return "Known charge is \(miles(chargeSummary.minRangeMeters)) miles of range"
        case 2:
            return "Known charges are \(miles(chargeSummary.minRangeMeters)) and \(miles(chargeSummary.maxRangeMeters)) miles of range"
        default:
            return "Known charges range from \(miles(chargeSummary.minRangeMeters)) to \(miles(chargeSummary.maxRangeMeters)) miles, median \(miles(chargeSummary.medianRangeMeters)) miles"
        }
    }

    private func miles(_ meters: Double) -> Int {
        max(1, Int((meters / 1609.344).rounded()))
    }
}
