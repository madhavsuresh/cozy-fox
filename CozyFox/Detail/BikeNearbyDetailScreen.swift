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
                    let picks = model.snapshot.nearbyBikePicks
                    if let headline = picks.first {
                        map(for: picks)
                        ChicagoCard(title: headline.station.name,
                                    eyebrow: "Closest e-bike",
                                    ornament: .icon(systemName: "bicycle")) {
                            headlineBlock(for: headline)
                        }
                        if picks.count > 1 {
                            ChicagoCard(title: "Also nearby",
                                        eyebrow: "Divvy",
                                        ornament: .icon(systemName: "list.bullet")) {
                                VStack(spacing: ChicagoSpacing.xs) {
                                    ForEach(Array(picks.dropFirst().enumerated()), id: \.element.station.id) { index, pick in
                                        secondaryRow(for: pick)
                                        if index < picks.count - 2 {
                                            Rectangle()
                                                .fill(ChicagoPalette.cornflower.opacity(0.25))
                                                .frame(height: ChicagoSpacing.Stroke.hairline)
                                        }
                                    }
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

    @ViewBuilder
    private func headlineBlock(for pick: NearestBikePick) -> some View {
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

    @ViewBuilder
    private func secondaryRow(for pick: NearestBikePick) -> some View {
        Button(action: { openInAppleMaps(pick: pick) }) {
            HStack(alignment: .center, spacing: ChicagoSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.station.name)
                        .font(ChicagoTypography.displaySM())
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(pick.walkingMinutes) min walk")
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                }
                Spacer(minLength: ChicagoSpacing.sm)
                BigNumber(
                    pick.station.eBikesAvailable,
                    unit: pick.station.eBikesAvailable == 1 ? "e-bike" : "e-bikes",
                    size: .md,
                    tone: pick.station.isScarce ? .warning : .accent,
                    accessibilityLabel: "\(pick.station.eBikesAvailable) e-bikes available"
                )
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.vertical, ChicagoSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this station in Apple Maps")
    }

    private func openInAppleMaps(pick: NearestBikePick) {
        let coord = CLLocationCoordinate2D(
            latitude: pick.station.latitude,
            longitude: pick.station.longitude
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = pick.station.name
        item.openInMaps()
    }

    private func map(for picks: [NearestBikePick]) -> some View {
        Map(initialPosition: .region(fittingRegion(for: picks))) {
            ForEach(picks, id: \.station.id) { pick in
                Marker(pick.station.name,
                       coordinate: CLLocationCoordinate2D(
                        latitude: pick.station.latitude,
                        longitude: pick.station.longitude
                       ))
                    .tint(ChicagoPalette.flagBlue)
            }
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

    private func fittingRegion(for picks: [NearestBikePick]) -> MKCoordinateRegion {
        var lats = picks.map(\.station.latitude)
        var lons = picks.map(\.station.longitude)
        if let user = model.location.lastKnown {
            lats.append(user.latitude)
            lons.append(user.longitude)
        }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            // Fallback — single Chicago-ish region. Shouldn't happen since
            // callers gate on `picks.first` being non-nil.
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        // 30% padding so pins sit inside the frame, with a small floor so a
        // single-point region doesn't render fully zoomed in.
        let latDelta = max((maxLat - minLat) * 1.3, 0.006)
        let lonDelta = max((maxLon - minLon) * 1.3, 0.006)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}
