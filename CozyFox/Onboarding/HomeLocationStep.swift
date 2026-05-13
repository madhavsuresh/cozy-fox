import SwiftUI
import MapKit
import TransitCache
import TransitModels

struct HomeLocationStep: View {
    let next: () -> Void

    @Environment(AppViewModel.self) private var model
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)
    @State private var didRequestPermission = false

    var body: some View {
        VStack {
            Text("Where's home?")
                .font(.title2.weight(.semibold))
                .padding(.top)
            Text("We use a small invisible region around this point to detect when you leave or arrive. No continuous tracking.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Map(position: $camera) {
                if let coordinate {
                    Marker("Home", coordinate: coordinate)
                        .tint(.green)
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .frame(maxHeight: .infinity)
            .gesture(LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 0)))
            .onTapGesture { /* hook reader proxy if needed */ }

            Button(action: useCurrentLocation) {
                Label("Use my current location", systemImage: "location.fill")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)

            Button("Set home", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(coordinate == nil)
                .padding(.horizontal)
                .padding(.bottom)
        }
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
