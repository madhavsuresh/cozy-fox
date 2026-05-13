import SwiftUI
import MapKit
import TransitDomain
import TransitModels

struct BikeNearbyDetailScreen: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        NavigationStack {
            VStack {
                if let pick = model.snapshot.nearestBike {
                    Map {
                        Marker(pick.station.name,
                               coordinate: CLLocationCoordinate2D(
                                latitude: pick.station.latitude,
                                longitude: pick.station.longitude
                               ))
                            .tint(.green)
                        UserAnnotation()
                    }
                    .mapControls { MapUserLocationButton() }
                    .frame(height: 240)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(pick.station.name).font(.title2.weight(.semibold))
                        Text("\(pick.walkingMinutes) min walk · \(pick.station.eBikesAvailable) e-bikes at station")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if pick.bestRangeMeters > 0 {
                            Text("Best available range: \(Int(pick.bestRangeMiles.rounded())) mi")
                                .font(.subheadline)
                        }
                        if pick.freeFloatingNearby > 0 {
                            Text("\(pick.freeFloatingNearby) free-floating e-bike\(pick.freeFloatingNearby == 1 ? "" : "s") nearby")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        "No e-bikes nearby",
                        systemImage: "bicycle",
                        description: Text("No Divvy e-bikes within walking distance of your last known location.")
                    )
                }
                Spacer()
            }
            .navigationTitle("E-bikes nearby")
        }
    }
}
