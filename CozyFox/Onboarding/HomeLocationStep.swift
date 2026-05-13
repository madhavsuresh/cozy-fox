import ChicagoTheme
import MapKit
import SwiftUI
import TransitCache
import TransitModels

struct HomeLocationStep: View {
    let next: () -> Void

    @Environment(AppViewModel.self) private var model
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)
    @State private var didRequestPermission = false

    var body: some View {
        VStack(spacing: ChicagoSpacing.md) {
            VStack(spacing: ChicagoSpacing.xs) {
                Text("Where's home?")
                    .font(ChicagoTypography.displayLG())
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Text("We use a small invisible region around this point to detect when you leave or arrive. No continuous tracking.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ChicagoSpacing.md)
            }
            .padding(.top, ChicagoSpacing.md)

            Map(position: $camera) {
                if let coordinate {
                    Marker("Home", coordinate: coordinate)
                        .tint(ChicagoPalette.starRed)
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
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

            primaryButton("Set home", action: save, disabled: coordinate == nil)
                .padding(.horizontal, ChicagoSpacing.md)
                .padding(.bottom, ChicagoSpacing.md)
        }
        .background(ChicagoPalette.Surface.background)
        .onAppear {
            if !didRequestPermission {
                didRequestPermission = true
                model.location.requestPermission()
            }
        }
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

    private func save() {
        guard let coordinate else { return }
        var anchors = model.preferences.loadCommuteAnchors()
        anchors.home = .init(latitude: coordinate.latitude, longitude: coordinate.longitude, label: "Home")
        model.preferences.saveCommuteAnchors(anchors)
        model.location.updateAnchors(anchors)
        next()
    }
}

extension MKCoordinateRegion {
    static var chicagoLoop: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.8819, longitude: -87.6278),
            span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
        )
    }
}

/// Shared primary-action button used across onboarding — Big Shoulders ALL CAPS on Flag Blue.
@ViewBuilder
func primaryButton(_ title: String, action: @escaping () -> Void, disabled: Bool = false) -> some View {
    Button(action: action) {
        Text(title)
            .font(ChicagoTypography.displayMD(relativeTo: .headline))
            .textCase(.uppercase)
            .tracking(1)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, ChicagoSpacing.md)
            .background(
                (disabled ? ChicagoPalette.Gray.light : ChicagoPalette.flagBlue),
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
            )
    }
    .buttonStyle(.plain)
    .disabled(disabled)
}
