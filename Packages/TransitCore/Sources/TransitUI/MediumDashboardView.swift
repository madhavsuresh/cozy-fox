import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

/// Three-block dashboard: train | bus | bike. Used inside the medium
/// home-screen widget and the main app dashboard "Near You" surface,
/// so a single rewrite refreshes both.
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

    public struct MetraPick: Sendable, Hashable {
        public let route: String
        public let stationLabel: String
        public let predictions: [MetraPrediction]
        public init(route: String, stationLabel: String, predictions: [MetraPrediction]) {
            self.route = route
            self.stationLabel = stationLabel
            self.predictions = predictions
        }
    }

    public let train: TrainPick?
    public let bus: BusPick?
    public let metra: MetraPick?
    public let bike: NearestBikePick?
    public let alerts: [ServiceAlert]
    public let vehiclePositions: [VehiclePosition]
    public let trainsFetchedAt: Date?
    public let isStale: Bool
    public let now: Date
    /// Optional Phase 3 corrections, one per mode. `nil` ⇒ the
    /// corresponding block view renders without the secondary line, which
    /// is the right behaviour when the host has no bias store (e.g. the
    /// widget process — see `MediumWidgetWrapper` for the deferral
    /// rationale).
    public let trainBiasCorrection: ArrivalBiasCorrection?
    public let busBiasCorrection: ArrivalBiasCorrection?
    public let metraBiasCorrection: ArrivalBiasCorrection?

    public init(
        train: TrainPick?,
        bus: BusPick?,
        metra: MetraPick? = nil,
        bike: NearestBikePick?,
        alerts: [ServiceAlert],
        vehiclePositions: [VehiclePosition] = [],
        trainsFetchedAt: Date? = nil,
        isStale: Bool,
        now: Date = .now,
        trainBiasCorrection: ArrivalBiasCorrection? = nil,
        busBiasCorrection: ArrivalBiasCorrection? = nil,
        metraBiasCorrection: ArrivalBiasCorrection? = nil
    ) {
        self.train = train
        self.bus = bus
        self.metra = metra
        self.bike = bike
        self.alerts = alerts
        self.vehiclePositions = vehiclePositions
        self.trainsFetchedAt = trainsFetchedAt
        self.isStale = isStale
        self.now = now
        self.trainBiasCorrection = trainBiasCorrection
        self.busBiasCorrection = busBiasCorrection
        self.metraBiasCorrection = metraBiasCorrection
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let train {
                TrainBlockView(
                    arrivals: train.arrivals,
                    title: train.title,
                    directionLabel: train.directionLabel,
                    now: now,
                    vehiclePositions: vehiclePositions,
                    arrivalsFetchedAt: trainsFetchedAt,
                    biasCorrection: trainBiasCorrection
                )
            } else {
                emptyBlock("Pick a train")
            }
            divider
            if let bus {
                BusBlockView(
                    predictions: bus.predictions,
                    routeLabel: bus.route,
                    stopLabel: bus.stopLabel,
                    now: now,
                    biasCorrection: busBiasCorrection
                )
            } else {
                emptyBlock("Pick a bus")
            }
            divider
            if let metra {
                MetraBlockView(
                    predictions: metra.predictions,
                    routeLabel: metra.route,
                    stationLabel: metra.stationLabel,
                    now: now,
                    biasCorrection: metraBiasCorrection
                )
            } else {
                emptyBlock("Pick Metra")
            }
            divider
            BikeBlockView(pick: bike)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 2) {
                AlertBadge(alerts: alerts)
                if isStale {
                    Text("Stale")
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.light)
                        .padding(.horizontal, ChicagoSpacing.xs)
                }
            }
            .padding(ChicagoSpacing.xs)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(ChicagoPalette.Gray.light.opacity(0.32))
            .frame(width: ChicagoSpacing.Stroke.hairline)
            .padding(.vertical, ChicagoSpacing.xs)
    }

    private func emptyBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(ChicagoPalette.Gray.light)
            Text(message)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
