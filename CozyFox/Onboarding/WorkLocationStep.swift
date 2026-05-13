import ChicagoTheme
import MapKit
import SwiftUI
import TransitModels

struct WorkLocationStep: View {
    let next: () -> Void

    @Environment(AppViewModel.self) private var model
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)

    var body: some View {
        VStack(spacing: ChicagoSpacing.md) {
            VStack(spacing: ChicagoSpacing.xs) {
                Text("Where do you work?")
                    .font(ChicagoTypography.displayLG())
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Text("Optional — skip if you work from home. We'll fall back to time-of-day for direction.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ChicagoSpacing.md)
            }
            .padding(.top, ChicagoSpacing.md)

            Map(position: $camera) {
                if let coordinate {
                    Marker("Work", coordinate: coordinate).tint(ChicagoPalette.bahama)
                }
                UserAnnotation()
            }
            .mapControls { MapUserLocationButton() }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg))
            .padding(.horizontal, ChicagoSpacing.md)

            Button(action: useCurrentLocation) {
                Label("Use my current location", systemImage: "location.fill")
                    .font(ChicagoTypography.body(.medium, relativeTo: .callout))
            }
            .buttonStyle(.bordered)
            .tint(ChicagoPalette.flagBlue)
            .padding(.horizontal, ChicagoSpacing.md)

            HStack(spacing: ChicagoSpacing.md) {
                Button(action: { saveAndContinue(nil) }) {
                    Text("Skip")
                        .font(ChicagoTypography.displayMD(relativeTo: .headline))
                        .textCase(.uppercase)
                        .tracking(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ChicagoSpacing.md)
                        .background(
                            ChicagoPalette.Surface.elevated,
                            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                        )
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                }
                .buttonStyle(.plain)
                primaryButton("Set work", action: { saveAndContinue(coordinate) }, disabled: coordinate == nil)
            }
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.bottom, ChicagoSpacing.md)
        }
        .background(ChicagoPalette.Surface.background)
    }

    private func useCurrentLocation() {
        Task {
            await model.location.refreshLocation()
            if let last = model.location.lastKnown {
                coordinate = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
                camera = .camera(MapCamera(centerCoordinate: coordinate!, distance: 1_000))
            }
        }
    }

    private func saveAndContinue(_ coord: CLLocationCoordinate2D?) {
        var anchors = model.preferences.loadCommuteAnchors()
        if let coord {
            anchors.work = .init(latitude: coord.latitude, longitude: coord.longitude, label: "Work")
        } else {
            anchors.work = nil
        }
        model.preferences.saveCommuteAnchors(anchors)
        model.location.updateAnchors(anchors)
        next()
    }
}
