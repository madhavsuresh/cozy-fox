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
            bike: entry.preferences.isModeVisible(.bikes) ? entry.snapshot.nearestBike : nil,
            alerts: alerts,
            vehiclePositions: entry.snapshot.vehiclePositions,
            trainsFetchedAt: entry.snapshot.trainsFetchedAt,
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

        if let pinned = entry.preferences.pinnedLine {
            let arrivals = entry.snapshot.trainArrivals
                .filter { $0.line == pinned }
                .filter {
                    entry.preferences.pinnedStationId == nil
                        || $0.stationId == entry.preferences.pinnedStationId
                }
                .filter {
                    entry.preferences.pinnedTrainDestination == nil
                        || $0.destinationName == entry.preferences.pinnedTrainDestination
                }
            guard let first = arrivals.first else { return nil }
            return MediumDashboardView.TrainPick(
                title: first.line.shortName,
                directionLabel: entry.preferences.pinnedTrainDestination ?? first.destinationName,
                arrivals: arrivals
            )
        }

        guard entry.preferences.isModeVisible(.trains),
              let first = entry.snapshot.trainArrivals.first(where: {
                  entry.preferences.isTrainLineVisible($0.line)
              }) else { return nil }
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

        if let pinned = entry.preferences.pinnedBusRoute {
            let predictions = entry.snapshot.busPredictions
                .filter { $0.route == pinned }
                .filter {
                    entry.preferences.pinnedBusStopId == nil
                        || $0.stopId == entry.preferences.pinnedBusStopId
                }
                .filter {
                    entry.preferences.pinnedBusDirection == nil
                        || $0.directionName == entry.preferences.pinnedBusDirection
                }
            guard let first = predictions.first else { return nil }
            return MediumDashboardView.BusPick(
                route: first.route,
                stopLabel: first.stopName,
                predictions: predictions
            )
        }

        guard entry.preferences.isModeVisible(.buses),
              let first = entry.snapshot.busPredictions.first(where: {
                  entry.preferences.isBusRouteVisible($0.route)
              }) else { return nil }
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
            ?? entry.preferences.pinnedLine
            ?? entry.snapshot.trainArrivals.first(where: {
                entry.preferences.isTrainLineVisible($0.line)
            })?.line
    }

    private var alertBusRoute: String? {
        entry.preferences.plannedTripPin?.bus?.route
            ?? entry.preferences.pinnedBusRoute
            ?? entry.snapshot.busPredictions.first(where: {
                entry.preferences.isBusRouteVisible($0.route)
            })?.route
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

        if let pinned = entry.preferences.pinnedMetraRoute {
            let predictions = entry.snapshot.metraPredictions
                .filter { $0.routeId == pinned }
                .filter {
                    entry.preferences.pinnedMetraStationId == nil
                        || $0.stationId == entry.preferences.pinnedMetraStationId
                }
                .filter {
                    entry.preferences.pinnedMetraDirectionId == nil
                        || $0.directionId == entry.preferences.pinnedMetraDirectionId
                }
            guard let first = predictions.first else { return nil }
            return MediumDashboardView.MetraPick(
                route: first.routeId,
                stationLabel: first.stationName,
                predictions: predictions
            )
        }

        guard entry.preferences.isModeVisible(.metra),
              let first = entry.snapshot.metraPredictions.first(where: {
                  entry.preferences.isMetraRouteVisible($0.routeId)
              }) else { return nil }
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
            ?? entry.preferences.pinnedMetraRoute
            ?? entry.snapshot.metraPredictions.first(where: {
                entry.preferences.isMetraRouteVisible($0.routeId)
            })?.routeId
    }
}
