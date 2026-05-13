import SwiftUI
import TransitModels
import TransitDomain

/// The user's described medium widget: three blocks side-by-side.
public struct MediumDashboardView: View {
    public struct TrainPick: Sendable, Hashable {
        public let title: String
        public let directionLabel: String?
        public let arrivals: [Arrival]
        public init(title: String, directionLabel: String?, arrivals: [Arrival]) {
            self.title = title
            self.directionLabel = directionLabel
            self.arrivals = arrivals
        }
    }

    public struct BusPick: Sendable, Hashable {
        public let route: String
        public let stopLabel: String
        public let predictions: [BusPrediction]
        public init(route: String, stopLabel: String, predictions: [BusPrediction]) {
            self.route = route
            self.stopLabel = stopLabel
            self.predictions = predictions
        }
    }

    public let train: TrainPick?
    public let bus: BusPick?
    public let bike: NearestBikePick?
    public let alerts: [ServiceAlert]
    public let isStale: Bool

    public init(
        train: TrainPick?,
        bus: BusPick?,
        bike: NearestBikePick?,
        alerts: [ServiceAlert],
        isStale: Bool
    ) {
        self.train = train
        self.bus = bus
        self.bike = bike
        self.alerts = alerts
        self.isStale = isStale
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let train {
                TrainBlockView(
                    arrivals: train.arrivals,
                    title: train.title,
                    directionLabel: train.directionLabel
                )
            } else {
                emptyBlock("Pick a train")
            }
            Divider()
            if let bus {
                BusBlockView(
                    predictions: bus.predictions,
                    routeLabel: bus.route,
                    stopLabel: bus.stopLabel
                )
            } else {
                emptyBlock("Pick a bus")
            }
            Divider()
            BikeBlockView(pick: bike)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                AlertBadge(alerts: alerts)
                if isStale {
                    Text("stale")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                }
            }
            .padding(6)
        }
    }

    private func emptyBlock(_ message: String) -> some View {
        VStack {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
