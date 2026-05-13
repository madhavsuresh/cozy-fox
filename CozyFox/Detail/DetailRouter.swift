import SwiftUI

struct DetailRouter: View {
    let detail: DetailDestination

    var body: some View {
        switch detail {
        case .train(let stationId):
            TrainDetailScreen(stationId: stationId)
        case .bus(let route, let stopId):
            BusDetailScreen(route: route, stopId: stopId)
        case .bikeNearest:
            BikeNearbyDetailScreen()
        }
    }
}
