import SwiftUI
import TransitModels
import TransitDomain

public struct TrainBlockView: View {
    public let arrivals: [Arrival]
    public let title: String
    public let directionLabel: String?

    public init(arrivals: [Arrival], title: String, directionLabel: String?) {
        self.arrivals = arrivals
        self.title = title
        self.directionLabel = directionLabel
    }

    public var body: some View {
        let line = arrivals.first?.line ?? .red
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(line.swiftUIColor)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if let directionLabel {
                Text(directionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            ForEach(arrivals.prefix(2), id: \.id) { arrival in
                arrivalRow(for: arrival)
            }
            if arrivals.isEmpty {
                Text("No data")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func arrivalRow(for arrival: Arrival) -> some View {
        let label = ArrivalFormatter.label(for: arrival)
        return HStack(spacing: 4) {
            Text(label.shortText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
            if arrival.isDelayed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}

#Preview {
    TrainBlockView(
        arrivals: [
            Arrival(
                id: "1", line: .red, runNumber: "418",
                destinationName: "95th/Dan Ryan", stationId: 40380,
                stationName: "Clark/Division", stopId: 30074,
                directionCode: "1",
                predictedAt: .now, arrivalAt: .now.addingTimeInterval(240),
                isApproaching: false, isDelayed: false, isFault: false, isScheduled: false
            ),
            Arrival(
                id: "2", line: .red, runNumber: "419",
                destinationName: "95th/Dan Ryan", stationId: 40380,
                stationName: "Clark/Division", stopId: 30074,
                directionCode: "1",
                predictedAt: .now, arrivalAt: .now.addingTimeInterval(720),
                isApproaching: false, isDelayed: false, isFault: false, isScheduled: false
            ),
        ],
        title: "Red Line",
        directionLabel: "→ 95th"
    )
    .frame(width: 130, height: 130)
}
