import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public struct TrainBlockView: View {
    public let arrivals: [Arrival]
    public let title: String
    public let directionLabel: String?
    public let now: Date
    public let vehiclePositions: [VehiclePosition]
    public let arrivalsFetchedAt: Date?

    public init(arrivals: [Arrival],
                title: String,
                directionLabel: String?,
                now: Date = .now,
                vehiclePositions: [VehiclePosition] = [],
                arrivalsFetchedAt: Date? = nil) {
        self.arrivals = arrivals
        self.title = title
        self.directionLabel = directionLabel
        self.now = now
        self.vehiclePositions = vehiclePositions
        self.arrivalsFetchedAt = arrivalsFetchedAt
    }

    public var body: some View {
        let line = arrivals.first?.line ?? .red
        let assessments = GhostTrainDetector().assessments(
            for: arrivals,
            vehiclePositions: vehiclePositions,
            arrivalsFetchedAt: arrivalsFetchedAt,
            now: now
        )
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                RouteBadge(line: line, size: .sm)
                Text(title)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let directionLabel {
                Text(directionLabel)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let first = arrivals.first {
                let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(now) / 60).rounded()))
                let firstAssessment = assessments[first.id]
                let isGhostLikely = firstAssessment?.isGhostLikely == true
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed || isGhostLikely ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next \(line.displayName) train"
                    )
                    if first.isDelayed || isGhostLikely {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(ChicagoPalette.starRed)
                            .accessibilityHidden(true)
                    }
                }
                if let badge = GhostTrainBadge(firstAssessment) {
                    badge
                }
                HeadwayDotStrip(
                    arrivals: arrivals.prefix(8).map(\.arrivalAt),
                    accent: line.swiftUIColor,
                    now: now,
                    complications: arrivals.prefix(8).map { assessments[$0.id]?.headwayComplication }
                )
            } else {
                Text("No data")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        title: "Clark/Division",
        directionLabel: "→ 95th"
    )
    .frame(width: 150, height: 150)
}
