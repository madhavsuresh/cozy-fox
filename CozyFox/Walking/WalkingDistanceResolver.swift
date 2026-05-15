import Foundation
import MapKit
import TransitModels

/// Resolves access routes from a user location to transit stops using MapKit.
/// Hits the persistent cache first; on miss, kicks off
/// async `MKDirections` fetches whose results land in the `@Observable` store
/// and trigger SwiftUI re-renders.
@MainActor
final class WalkingDistanceResolver {
    let store: WalkingDistanceStore

    init(store: WalkingDistanceStore) {
        self.store = store
    }

    /// Phase 5: applies the per-user `walkSpeedEstimate` to a cached
    /// `WalkingDistance` if it's past the confidence gate. Walking only —
    /// cycling speeds vary too much by effort/terrain/equipment for a
    /// single multiplicative correction to be meaningful. Distance stays
    /// unmodified (it's geography, not pace).
    private func corrected(_ raw: WalkingDistance?, mode: AccessTravelMode) -> WalkingDistance? {
        guard let raw else { return nil }
        guard mode == .walking else { return raw }
        guard let ratio = store.walkSpeedEstimate.confidentRatio() else { return raw }
        return WalkingDistance(
            meters: raw.meters,
            expectedTravelTime: raw.expectedTravelTime * ratio,
            cachedAt: raw.cachedAt
        )
    }

    /// Fresh cached value or nil. Synchronous — safe to call from SwiftUI
    /// body. Phase 5: applies the per-user walk-speed correction to
    /// `expectedTravelTime` if the estimate is past its confidence gate.
    func cached(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        corrected(store.fresh(origin: origin, destinationKey: destinationKey, mode: mode), mode: mode)
    }

    func cached(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        corrected(store.fresh(origin: origin, stationId: stationId), mode: .walking)
    }

    func cached(origin: (lat: Double, lon: Double), intercampusStop: IntercampusStop) -> WalkingDistance? {
        cached(
            origin: origin,
            destinationKey: WalkingDistanceStore.intercampusStopDestinationKey(stopId: intercampusStop.id),
            mode: .walking
        )
    }

    /// Stale fallback so the chip can render a known walking value while
    /// the daily refresh is in flight, instead of dropping back to
    /// Haversine and then visibly jumping when MapKit returns. Phase 5
    /// correction applies here too.
    func staleFallback(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        corrected(store.anyCached(origin: origin, destinationKey: destinationKey, mode: mode), mode: mode)
    }

    func staleFallback(origin: (lat: Double, lon: Double), stationId: Int) -> WalkingDistance? {
        corrected(store.anyCached(origin: origin, stationId: stationId), mode: .walking)
    }

    func staleFallback(origin: (lat: Double, lon: Double), intercampusStop: IntercampusStop) -> WalkingDistance? {
        staleFallback(
            origin: origin,
            destinationKey: WalkingDistanceStore.intercampusStopDestinationKey(stopId: intercampusStop.id),
            mode: .walking
        )
    }

    /// Kick off a MapKit fetch for `(origin, station)` if we don't already
    /// have a fresh entry, an inflight request, or a recent failure. The
    /// result lands in the store; SwiftUI views observing it re-render.
    func ensureFresh(
        origin: (lat: Double, lon: Double),
        station: LStation,
        modes: [AccessTravelMode] = [.walking]
    ) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.stationDestinationKey(stationId: station.id),
                latitude: station.latitude,
                longitude: station.longitude
            ),
            modes: modes
        )
    }

    /// Convenience: ensure-fresh for a batch of stations near `origin`.
    /// Used by the pinned-line card on appear and by the background
    /// refresh hook.
    func ensureFresh(
        origin: (lat: Double, lon: Double),
        stations: [LStation],
        modes: [AccessTravelMode] = [.walking]
    ) {
        for station in stations {
            ensureFresh(origin: origin, station: station, modes: modes)
        }
    }

    func ensureFresh(
        origin: (lat: Double, lon: Double),
        stop: BusStop,
        modes: [AccessTravelMode] = [.walking]
    ) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.busStopDestinationKey(stopId: stop.id),
                latitude: stop.latitude,
                longitude: stop.longitude
            ),
            modes: modes
        )
    }

    func ensureFresh(
        origin: (lat: Double, lon: Double),
        stops: [BusStop],
        modes: [AccessTravelMode] = [.walking]
    ) {
        for stop in stops {
            ensureFresh(origin: origin, stop: stop, modes: modes)
        }
    }

    func ensureFresh(
        origin: (lat: Double, lon: Double),
        metraStation: MetraStation,
        modes: [AccessTravelMode] = [.walking]
    ) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.metraStationDestinationKey(stationId: metraStation.id),
                latitude: metraStation.latitude,
                longitude: metraStation.longitude
            ),
            modes: modes
        )
    }

    func ensureFresh(
        origin: (lat: Double, lon: Double),
        metraStations: [MetraStation],
        modes: [AccessTravelMode] = [.walking]
    ) {
        for station in metraStations {
            ensureFresh(origin: origin, metraStation: station, modes: modes)
        }
    }

    func ensureFresh(origin: (lat: Double, lon: Double), intercampusStop: IntercampusStop) {
        ensureFresh(
            origin: origin,
            destination: AccessRouteDestination(
                key: WalkingDistanceStore.intercampusStopDestinationKey(stopId: intercampusStop.id),
                latitude: intercampusStop.latitude,
                longitude: intercampusStop.longitude
            ),
            mode: .walking
        )
    }

    func ensureFresh(origin: (lat: Double, lon: Double), intercampusStops: [IntercampusStop]) {
        for stop in intercampusStops {
            ensureFresh(origin: origin, intercampusStop: stop)
        }
    }

    private func ensureFresh(
        origin: (lat: Double, lon: Double),
        destination: AccessRouteDestination,
        modes: [AccessTravelMode]
    ) {
        for mode in modes {
            ensureFresh(origin: origin, destination: destination, mode: mode)
        }
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
        guard await MapKitDirectionsLimiter.waitForTurn() else { return }
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
            await MapKitDirectionsLimiter.recordFailure(error)
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

private actor MapKitDirectionsLimiter {
    static let shared = MapKitDirectionsLimiter()

    private let windowSize: TimeInterval = 60
    private let maxRequestsPerWindow = 40
    private let minimumSpacing: TimeInterval = 1.25

    private var recentRequestStarts: [Date] = []
    private var nextAllowedStart = Date.distantPast

    static func waitForTurn() async -> Bool {
        while !Task.isCancelled {
            if let delay = await shared.delayBeforeNextRequest() {
                let nanoseconds = UInt64(max(0.1, min(delay, 60)) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return false
                }
            } else {
                return true
            }
        }
        return false
    }

    static func recordFailure(_ error: Error) async {
        let nsError = error as NSError
        guard nsError.domain == "GEOErrorDomain", nsError.code == -3 else { return }
        await shared.pause(for: throttleResetDelay(from: nsError) ?? 30)
    }

    private static func throttleResetDelay(from error: NSError) -> TimeInterval? {
        if let reset = error.userInfo["timeUntilReset"] as? TimeInterval {
            return reset
        }
        if let reset = error.userInfo["timeUntilReset"] as? NSNumber {
            return reset.doubleValue
        }
        guard let details = error.userInfo["details"] as? [[String: Any]] else {
            return nil
        }
        for detail in details {
            if let reset = detail["timeUntilReset"] as? TimeInterval {
                return reset
            }
            if let reset = detail["timeUntilReset"] as? NSNumber {
                return reset.doubleValue
            }
        }
        return nil
    }

    private func delayBeforeNextRequest(now: Date = Date()) -> TimeInterval? {
        recentRequestStarts.removeAll { now.timeIntervalSince($0) >= windowSize }

        let spacingDelay = max(0, nextAllowedStart.timeIntervalSince(now))
        let windowDelay: TimeInterval
        if recentRequestStarts.count >= maxRequestsPerWindow,
           let oldest = recentRequestStarts.first
        {
            windowDelay = max(0, windowSize - now.timeIntervalSince(oldest))
        } else {
            windowDelay = 0
        }

        let delay = max(spacingDelay, windowDelay)
        guard delay <= 0 else { return delay }

        recentRequestStarts.append(now)
        nextAllowedStart = now.addingTimeInterval(minimumSpacing)
        return nil
    }

    private func pause(for delay: TimeInterval) {
        nextAllowedStart = max(nextAllowedStart, Date().addingTimeInterval(delay))
    }
}
