import SwiftUI
import MapKit
import TransitModels

struct WorkLocationStep: View {
    let next: () -> Void

    @Environment(AppViewModel.self) private var model
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)

    var body: some View {
        VStack {
            Text("Where do you work?")
                .font(.title2.weight(.semibold))
                .padding(.top)
            Text("Optional — skip if you work from home. We'll fall back to time-of-day for direction.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Map(position: $camera) {
                if let coordinate {
                    Marker("Work", coordinate: coordinate).tint(.blue)
                }
                UserAnnotation()
            }
            .mapControls { MapUserLocationButton() }
            .frame(maxHeight: .infinity)

            Button(action: useCurrentLocation) {
                Label("Use my current location", systemImage: "location.fill")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            HStack {
                Button("Skip", action: { saveAndContinue(nil) })
                    .buttonStyle(.bordered)
                Button("Set work", action: { saveAndContinue(coordinate) })
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinate == nil)
            }
            .controlSize(.large)
            .padding()
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
