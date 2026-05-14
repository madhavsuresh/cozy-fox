import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct MediumWidgetWrapper: View {
    let entry: DashboardEntry

    var body: some View {
        let train = displayedTrain
        let bus = displayedBus
        let metra = displayedMetra
        let alerts = entry.configuration.showAlerts
            ? entry.snapshot.activeAlerts.filtered(forLine: alertLine, busRoute: alertBusRoute, metraRoute: alertMetraRoute)
            : []
        MediumDashboardView(
            train: train,
            bus: bus,
            metra: metra,
            bike: entry.snapshot.nearestBike,
            alerts: alerts,
            isStale: entry.snapshot.isAnythingStale(),
            now: entry.date
        )
        .widgetURL(URL(string: "cozyfox://dashboard"))
    }

    private var displayedTrain: MediumDashboardView.TrainPick? {
        if let tripTrain = entry.preferences.plannedTripPin?.train {
            let arrivals = entry.snapshot.trainArrivals
                .filter { $0.line == tripTrain.line }
                .filter { tripTrain.stationId == nil || $0.stationId == tripTrain.stationId }
                .filter { tripTrain.destinationName == nil || $0.destinationName == tripTrain.destinationName }
            guard let first = arrivals.first else { return nil }
            return MediumDashboardView.TrainPick(
                title: tripTrain.line.shortName,
                directionLabel: tripTrain.destinationName ?? first.destinationName,
                arrivals: arrivals
            )
        }

        guard let first = entry.snapshot.trainArrivals.first else { return nil }
        return MediumDashboardView.TrainPick(
            title: first.line.shortName,
            directionLabel: first.destinationName,
            arrivals: entry.snapshot.trainArrivals.filter { $0.line == first.line }
        )
    }

    private var displayedBus: MediumDashboardView.BusPick? {
        if let tripBus = entry.preferences.plannedTripPin?.bus {
            let predictions = entry.snapshot.busPredictions
                .filter { $0.route == tripBus.route }
                .filter { tripBus.stopId == nil || $0.stopId == tripBus.stopId }
                .filter { tripBus.directionLabel == nil || $0.directionName == tripBus.directionLabel }
            guard let first = predictions.first else { return nil }
            return MediumDashboardView.BusPick(
                route: first.route,
                stopLabel: tripBus.stopName,
                predictions: predictions
            )
        }

        guard let first = entry.snapshot.busPredictions.first else { return nil }
        return MediumDashboardView.BusPick(
            route: first.route,
            stopLabel: first.stopName,
            predictions: entry.snapshot.busPredictions.filter {
                $0.route == first.route && $0.stopId == first.stopId
            }
        )
    }

    private var alertLine: LineColor? {
        entry.preferences.plannedTripPin?.train?.line
            ?? entry.snapshot.trainArrivals.first?.line
    }

    private var alertBusRoute: String? {
        entry.preferences.plannedTripPin?.bus?.route
            ?? entry.snapshot.busPredictions.first?.route
    }

    private var displayedMetra: MediumDashboardView.MetraPick? {
        if let tripMetra = entry.preferences.plannedTripPin?.metra {
            let predictions = entry.snapshot.metraPredictions
                .filter { $0.routeId == tripMetra.routeId }
                .filter { tripMetra.stationId == nil || $0.stationId == tripMetra.stationId }
                .filter { tripMetra.directionId == nil || $0.directionId == tripMetra.directionId }
            guard let first = predictions.first else { return nil }
            return MediumDashboardView.MetraPick(
                route: first.routeId,
                stationLabel: tripMetra.stationName,
                predictions: predictions
            )
        }

        guard let first = entry.snapshot.metraPredictions.first else { return nil }
        return MediumDashboardView.MetraPick(
            route: first.routeId,
            stationLabel: first.stationName,
            predictions: entry.snapshot.metraPredictions.filter {
                $0.routeId == first.routeId && $0.stationId == first.stationId
            }
        )
    }

    private var alertMetraRoute: String? {
        entry.preferences.plannedTripPin?.metra?.routeId
            ?? entry.snapshot.metraPredictions.first?.routeId
    }
}
