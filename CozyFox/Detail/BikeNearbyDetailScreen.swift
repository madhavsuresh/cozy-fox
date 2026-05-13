import ChicagoTheme
import MapKit
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct BikeNearbyDetailScreen: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if let pick = model.snapshot.nearestBike {
                        map(for: pick)
                        ChicagoCard(title: pick.station.name,
                                    eyebrow: "Closest e-bike",
                                    ornament: .icon(systemName: "bicycle")) {
                            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.md) {
                                    BigNumber(
                                        pick.walkingMinutes,
                                        unit: "min walk",
                                        size: .lg,
                                        tone: pick.station.isScarce ? .warning : .primary,
                                        accessibilityLabel: "\(pick.walkingMinutes) minute walk"
                                    )
                                    if pick.bestRangeMeters > 0 {
                                        BigNumber(
                                            Int(pick.bestRangeMiles.rounded()),
                                            unit: "mi range",
                                            size: .md,
                                            tone: .accent,
                                            accessibilityLabel: "\(Int(pick.bestRangeMiles.rounded())) miles of range"
                                        )
                                    }
                                }
                                BikeAvailabilityBar(
                                    current: pick.station.eBikesAvailable,
                                    capacity: max(1, pick.station.capacity),
                                    scarce: pick.station.isScarce
                                )
                                if pick.freeFloatingNearby > 0 {
                                    Text("\(pick.freeFloatingNearby) free-floating e-bike\(pick.freeFloatingNearby == 1 ? "" : "s") nearby")
                                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                                        .foregroundStyle(ChicagoPalette.Gray.medium)
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "No e-bikes nearby",
                            systemImage: "bicycle",
                            description: Text("No Divvy e-bikes within walking distance of your last known location.")
                        )
                        .padding(ChicagoSpacing.md)
                    }
                    Spacer()
                }
                .padding(ChicagoSpacing.md)
            }
            .background(ChicagoPalette.Surface.background)
            .navigationTitle("E-bikes nearby")
        }
    }

    private func map(for pick: NearestBikePick) -> some View {
        Map {
            Marker(pick.station.name,
                   coordinate: CLLocationCoordinate2D(
                    latitude: pick.station.latitude,
                    longitude: pick.station.longitude
                   ))
                .tint(ChicagoPalette.flagBlue)
            UserAnnotation()
        }
        .mapControls { MapUserLocationButton() }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg)
                .strokeBorder(ChicagoPalette.cornflower.opacity(0.4),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
    }
}
