import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct MediumWidgetWrapper: View {
    let entry: DashboardEntry

    var body: some View {
        let train = entry.snapshot.trainArrivals.first
        let bus = entry.snapshot.busPredictions.first
        let alerts = entry.configuration.showAlerts
            ? entry.snapshot.activeAlerts.filtered(forLine: train?.line, busRoute: bus?.route)
            : []
        MediumDashboardView(
            train: train.map { first in
                MediumDashboardView.TrainPick(
                    title: first.line.shortName,
                    directionLabel: first.destinationName,
                    arrivals: entry.snapshot.trainArrivals.filter { $0.line == first.line }
                )
            },
            bus: bus.map { first in
                MediumDashboardView.BusPick(
                    route: first.route,
                    stopLabel: first.stopName,
                    predictions: entry.snapshot.busPredictions.filter {
                        $0.route == first.route && $0.stopId == first.stopId
                    }
                )
            },
            bike: entry.snapshot.nearestBike,
            alerts: alerts,
            isStale: entry.snapshot.isAnythingStale()
        )
        .widgetURL(URL(string: "cozyfox://dashboard"))
    }
}
