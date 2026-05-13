import SwiftUI
import TransitModels
import TransitDomain

public struct BusBlockView: View {
    public let predictions: [BusPrediction]
    public let routeLabel: String
    public let stopLabel: String

    public init(predictions: [BusPrediction], routeLabel: String, stopLabel: String) {
        self.predictions = predictions
        self.routeLabel = routeLabel
        self.stopLabel = stopLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(routeLabel)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                Text(stopLabel)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            ForEach(predictions.prefix(2), id: \.id) { prediction in
                row(for: prediction)
            }
            if predictions.isEmpty {
                Text("No buses")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(for prediction: BusPrediction) -> some View {
        let label = ArrivalFormatter.label(for: prediction)
        return HStack(spacing: 4) {
            Text(label.shortText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
            if prediction.isDelayed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}
