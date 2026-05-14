import Foundation
import MapKit
import TransitModels

/// Resolves walking distances from a user location to L stations using
/// MapKit. Hits the persistent cache first; on miss, kicks off async
/// `MKDirections` fetches whose results land in the `@Observable` store
/// and trigger SwiftUI re-renders.
@MainActor
final class WalkingDistanceResolver {
    let store: WalkingDistanceStore

    init(store: WalkingDistanceStore) {
        self.store = store
    }

    /// Fresh cached value or nil. Synchronous — safe to call from SwiftUI
    /// body.
    func cached(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        store.fresh(origin: origin, stationId: stationId)
    }

    /// Stale fallback so the chip can render a known walking value while
    /// the daily refresh is in flight, instead of dropping back to
    /// Haversine and then visibly jumping when MapKit returns.
    func staleFallback(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        store.anyCached(origin: origin, stationId: stationId)
    }

    /// Kick off a MapKit fetch for `(origin, station)` if we don't already
    /// have a fresh entry, an inflight request, or a recent failure. The
    /// result lands in the store; SwiftUI views observing it re-render.
    func ensureFresh(origin: (lat: Double, lon: Double), station: LStation) {
        let stationId = station.id
        if store.fresh(origin: origin, stationId: stationId) != nil { return }
        if store.isInflight(origin: origin, stationId: stationId) { return }
        if store.isInNegativeCache(origin: origin, stationId: stationId) { return }
        store.markInflight(origin: origin, stationId: stationId)
        let store = store
        Task { @MainActor in
            await Self.fetchAndStore(origin: origin, station: station, into: store)
            store.clearInflight(origin: origin, stationId: stationId)
        }
    }

    /// Convenience: ensure-fresh for a batch of stations near `origin`.
    /// Used by the pinned-line card on appear and by the background
    /// refresh hook.
    func ensureFresh(origin: (lat: Double, lon: Double), stations: [LStation]) {
        for station in stations {
            ensureFresh(origin: origin, station: station)
        }
    }

    private static func fetchAndStore(
        origin: (lat: Double, lon: Double),
        station: LStation,
        into store: WalkingDistanceStore
    ) async {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude)
        ))
        request.transportType = .walking

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                store.recordFailure(origin: origin, stationId: station.id)
                return
            }
            store.record(
                meters: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                origin: origin,
                stationId: station.id
            )
        } catch {
            // Includes Apple's rate-limit throttle. Negative cache absorbs
            // the next few seconds of attempts so we don't thrash.
            store.recordFailure(origin: origin, stationId: station.id)
        }
    }
}
