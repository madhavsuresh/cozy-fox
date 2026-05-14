import Foundation
import MapKit
import TransitModels

/// Resolves walking and cycling access routes from a user location to transit
/// stops using MapKit. Hits the persistent cache first; on miss, kicks off
/// async `MKDirections` fetches whose results land in the `@Observable` store
/// and trigger SwiftUI re-renders.
@MainActor
final class WalkingDistanceResolver {
    let store: WalkingDistanceStore

    init(store: WalkingDistanceStore) {
        self.store = store
    }

    /// Fresh cached value or nil. Synchronous — safe to call from SwiftUI
    /// body.
    func cached(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        store.fresh(origin: origin, destinationKey: destinationKey, mode: mode)
    }

    func cached(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        store.fresh(origin: origin, stationId: stationId)
    }

    /// Stale fallback so the chip can render a known walking value while
    /// the daily refresh is in flight, instead of dropping back to
    /// Haversine and then visibly jumping when MapKit returns.
    func staleFallback(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        store.anyCached(origin: origin, destinationKey: destinationKey, mode: mode)
    }

    func staleFallback(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        store.anyCached(origin: origin, stationId: stationId)
    }

    /// Kick off a MapKit fetch for `(origin, station)` if we don't already
    /// have a fresh entry, an inflight request, or a recent failure. The
    /// result lands in the store; SwiftUI views observing it re-render.
    func ensureFresh(origin: (lat: Double, lon: Double), station: LStation) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.stationDestinationKey(stationId: station.id),
                latitude: station.latitude,
                longitude: station.longitude
            )
        )
    }

    /// Convenience: ensure-fresh for a batch of stations near `origin`.
    /// Used by the pinned-line card on appear and by the background
    /// refresh hook.
    func ensureFresh(origin: (lat: Double, lon: Double), stations: [LStation]) {
        for station in stations {
            ensureFresh(origin: origin, station: station)
        }
    }

    func ensureFresh(origin: (lat: Double, lon: Double), stop: BusStop) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.busStopDestinationKey(stopId: stop.id),
                latitude: stop.latitude,
                longitude: stop.longitude
            )
        )
    }

    func ensureFresh(origin: (lat: Double, lon: Double), stops: [BusStop]) {
        for stop in stops {
            ensureFresh(origin: origin, stop: stop)
        }
    }

    func ensureFresh(origin: (lat: Double, lon: Double), metraStation: MetraStation) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.metraStationDestinationKey(stationId: metraStation.id),
                latitude: metraStation.latitude,
                longitude: metraStation.longitude
            )
        )
    }

    func ensureFresh(origin: (lat: Double, lon: Double), metraStations: [MetraStation]) {
        for station in metraStations {
            ensureFresh(origin: origin, metraStation: station)
        }
    }

    private func ensureFresh(
        origin: (lat: Double, lon: Double),
        destination: AccessRouteDestination
    ) {
        ensureFresh(origin: origin, destination: destination, mode: .walking)
        ensureFresh(origin: origin, destination: destination, mode: .cycling)
    }

    private func ensureFresh(
        origin: (lat: Double, lon: Double),
        destination: AccessRouteDestination,
        mode: AccessTravelMode
    ) {
        if store.fresh(origin: origin, destinationKey: destination.key, mode: mode) != nil { return }
        if store.isInflight(origin: origin, destinationKey: destination.key, mode: mode) { return }
        if store.isInNegativeCache(origin: origin, destinationKey: destination.key, mode: mode) { return }
        store.markInflight(origin: origin, destinationKey: destination.key, mode: mode)
        let store = store
        Task { @MainActor in
            await Self.fetchAndStore(
                origin: origin,
                destination: destination,
                mode: mode,
                into: store
            )
            store.clearInflight(origin: origin, destinationKey: destination.key, mode: mode)
        }
    }

    private static func fetchAndStore(
        origin: (lat: Double, lon: Double),
        destination: AccessRouteDestination,
        mode: AccessTravelMode,
        into store: WalkingDistanceStore
    ) async {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        ))
        request.transportType = mode.transportType

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                store.recordFailure(origin: origin, destinationKey: destination.key, mode: mode)
                return
            }
            store.record(
                meters: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                origin: origin,
                destinationKey: destination.key,
                mode: mode
            )
        } catch {
            // Includes Apple's rate-limit throttle. Negative cache absorbs
            // the next few seconds of attempts so we don't thrash.
            store.recordFailure(origin: origin, destinationKey: destination.key, mode: mode)
        }
    }
}

private struct AccessRouteDestination: Sendable {
    let key: String
    let latitude: Double
    let longitude: Double
}

private extension AccessTravelMode {
    var transportType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .cycling: .cycling
        }
    }
}
