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
                    let options = model.snapshot.nearbyBikeOptions
                    if let headline = options.first {
                        map(for: options)
                        ChicagoCard(title: title(for: headline),
                                    eyebrow: "Closest e-bike",
                                    ornament: .icon(systemName: "bicycle")) {
                            headlineBlock(for: headline)
                        }
                        if options.count > 1 {
                            ChicagoCard(title: "Also nearby",
                                        eyebrow: "Divvy",
                                        ornament: .icon(systemName: "list.bullet")) {
                                VStack(spacing: ChicagoSpacing.xs) {
                                    ForEach(Array(options.dropFirst().enumerated()), id: \.element.id) { index, option in
                                        secondaryRow(for: option)
                                        if index < options.count - 2 {
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
    private func headlineBlock(for option: NearbyBikeOption) -> some View {
        switch option {
        case .station(let pick):
            stationHeadlineBlock(for: pick)
        case .freeFloating(let pick):
            freeBikeHeadlineBlock(for: pick)
        }
    }

    private func stationHeadlineBlock(for pick: NearestBikePick) -> some View {
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
            BikeInventorySummary(
                dockedCount: pick.station.eBikesAvailable,
                chargeSummary: pick.dockedChargeSummary,
                scarce: pick.station.isScarce
            )
            BikeAvailabilityBar(
                current: pick.station.eBikesAvailable,
                capacity: max(1, pick.station.capacity),
                scarce: pick.station.isScarce
            )
        }
    }

    private func freeBikeHeadlineBlock(for pick: NearestFreeBikePick) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.md) {
                BigNumber(
                    pick.walkingMinutes,
                    unit: "min walk",
                    size: .lg,
                    tone: .primary,
                    accessibilityLabel: "\(pick.walkingMinutes) minute walk"
                )
                BigNumber(
                    Int(pick.bestRangeMiles.rounded()),
                    unit: "mi charge",
                    size: .md,
                    tone: .accent,
                    accessibilityLabel: "\(Int(pick.bestRangeMiles.rounded())) miles of range"
                )
            }
            Label("Free-floating e-bike", systemImage: "bicycle")
                .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.green)
        }
    }

    @ViewBuilder
    private func secondaryRow(for option: NearbyBikeOption) -> some View {
        Button(action: { openInAppleMaps(option: option) }) {
            HStack(alignment: .center, spacing: ChicagoSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: option))
                        .font(ChicagoTypography.displaySM())
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(option.walkingMinutes) min walk")
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                }
                Spacer(minLength: ChicagoSpacing.sm)
                secondaryTrailing(for: option)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.vertical, ChicagoSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this station in Apple Maps")
    }

    @ViewBuilder
    private func secondaryTrailing(for option: NearbyBikeOption) -> some View {
        switch option {
        case .station(let pick):
            BikeInventorySummary(
                dockedCount: pick.station.eBikesAvailable,
                chargeSummary: pick.dockedChargeSummary,
                scarce: pick.station.isScarce
            )
        case .freeFloating(let pick):
            VStack(alignment: .trailing, spacing: ChicagoSpacing.xs) {
                Image(systemName: "bicycle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(ChicagoPalette.green)
                Text("\(Int(pick.bestRangeMiles.rounded())) mi charge")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
            }
        }
    }

    private func openInAppleMaps(option: NearbyBikeOption) {
        let coord: CLLocationCoordinate2D
        let name: String
        switch option {
        case .station(let pick):
            coord = CLLocationCoordinate2D(
                latitude: pick.station.latitude,
                longitude: pick.station.longitude
            )
            name = pick.station.name
        case .freeFloating(let pick):
            coord = CLLocationCoordinate2D(
                latitude: pick.bike.latitude,
                longitude: pick.bike.longitude
            )
            name = "Free e-bike"
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = name
        item.openInMaps()
    }

    private func map(for options: [NearbyBikeOption]) -> some View {
        let stationPicks = stationPicks(for: options)
        let freePicks = freeBikePicks(for: options)
        return Map(initialPosition: .region(fittingRegion(for: stationPicks, freePicks: freePicks))) {
            ForEach(stationPicks, id: \.station.id) { pick in
                Marker(pick.station.name,
                       coordinate: CLLocationCoordinate2D(
                        latitude: pick.station.latitude,
                        longitude: pick.station.longitude
                       ))
                    .tint(ChicagoPalette.flagBlue)
            }
            ForEach(freePicks) { pick in
                Annotation("Free e-bike",
                           coordinate: CLLocationCoordinate2D(
                            latitude: pick.bike.latitude,
                            longitude: pick.bike.longitude
                           ),
                           anchor: .center) {
                    freeBikeMapIcon
                }
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

    private var freeBikeMapIcon: some View {
        Image(systemName: "bicycle")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(ChicagoPalette.green))
            .overlay(
                Circle()
                    .strokeBorder(.white, lineWidth: ChicagoSpacing.Stroke.regular)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
    }

    private func title(for option: NearbyBikeOption) -> String {
        switch option {
        case .station(let pick): pick.station.name
        case .freeFloating: "Free e-bike"
        }
    }

    private func stationPicks(for options: [NearbyBikeOption]) -> [NearestBikePick] {
        options.compactMap {
            if case .station(let pick) = $0 { return pick }
            return nil
        }
    }

    private func freeBikePicks(for options: [NearbyBikeOption]) -> [NearestFreeBikePick] {
        options.compactMap {
            if case .freeFloating(let pick) = $0 { return pick }
            return nil
        }
    }

    private func fittingRegion(for picks: [NearestBikePick], freePicks: [NearestFreeBikePick]) -> MKCoordinateRegion {
        var lats = picks.map(\.station.latitude)
        var lons = picks.map(\.station.longitude)
        lats.append(contentsOf: freePicks.map(\.bike.latitude))
        lons.append(contentsOf: freePicks.map(\.bike.longitude))
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
