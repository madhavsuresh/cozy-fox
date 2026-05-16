import Foundation
import MapKit
import TransitModels

struct IntercampusTrafficETASample: Sendable, Hashable {
    let travelTime: TimeInterval
    let distanceMeters: Double
}

protocol IntercampusTrafficETAFetching: Sendable {
    /// Returns a sample, or nil if the directions service couldn't produce a
    /// usable route (no route, throttled, network error). Throws on
    /// cancellation so the resolver can avoid caching aborted requests.
    func fetchEstimate(
        from origin: (latitude: Double, longitude: Double),
        to destination: (latitude: Double, longitude: Double),
        departingAt: Date
    ) async throws -> IntercampusTrafficETASample?
}

@MainActor
final class IntercampusTrafficETAResolver {
    private let maxTrafficEstimatesPerRefresh = 4
    private let maxVehiclePositionAge: TimeInterval = 3 * 60
    private let estimateTTL: TimeInterval = 90
    private let failureTTL: TimeInterval = 45

    private let fetcher: IntercampusTrafficETAFetching
    private var cache: [CacheKey: CacheEntry] = [:]

    init(fetcher: IntercampusTrafficETAFetching = MapKitIntercampusTrafficETAFetcher()) {
        self.fetcher = fetcher
    }

    func applyingTrafficEstimates(
        to arrivals: [IntercampusArrival],
        priorityStopIds: Set<String>,
        now: Date = .now
    ) async -> [IntercampusArrival] {
        guard !arrivals.isEmpty else { return arrivals }
        pruneCache(now: now)

        let candidates = trafficCandidates(
            from: arrivals,
            priorityStopIds: priorityStopIds,
            now: now
        )
        guard !candidates.isEmpty else { return arrivals }

        var adjustedById: [String: IntercampusArrival] = [:]
        var newRequestCount = 0

        for arrival in candidates {
            guard let key = CacheKey(arrival: arrival) else { continue }
            if let cached = cache[key], cached.expiresAt > now {
                if let estimate = cached.estimate {
                    adjustedById[arrival.id] = arrival.applyingTrafficEstimate(estimate)
                }
                continue
            }
            guard newRequestCount < maxTrafficEstimatesPerRefresh else { continue }
            newRequestCount += 1

            let estimate = await fetchTrafficEstimate(for: arrival, cacheKey: key, now: now)
            if let estimate {
                adjustedById[arrival.id] = arrival.applyingTrafficEstimate(estimate)
            }
        }

        return arrivals
            .map { adjustedById[$0.id] ?? $0 }
            .sorted { $0.arrivalAt < $1.arrivalAt }
    }

    private func trafficCandidates(
        from arrivals: [IntercampusArrival],
        priorityStopIds: Set<String>,
        now: Date
    ) -> [IntercampusArrival] {
        var seenStopDirections: Set<String> = []
        return arrivals
            .filter { canUseTraffic(for: $0, now: now) }
            .sorted {
                let lhsPriority = priorityStopIds.contains($0.stopId) ? 0 : 1
                let rhsPriority = priorityStopIds.contains($1.stopId) ? 0 : 1
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return $0.arrivalAt < $1.arrivalAt
            }
            .filter { arrival in
                seenStopDirections.insert("\(arrival.direction.rawValue)-\(arrival.stopId)").inserted
            }
    }

    private func canUseTraffic(for arrival: IntercampusArrival, now: Date) -> Bool {
        guard arrival.timeSource != .traffic,
              let location = arrival.vehicleLocation,
              IntercampusCatalog.stop(id: arrival.stopId) != nil
        else { return false }
        return abs(now.timeIntervalSince(location.observedAt)) <= maxVehiclePositionAge
    }

    private func fetchTrafficEstimate(
        for arrival: IntercampusArrival,
        cacheKey: CacheKey,
        now: Date
    ) async -> IntercampusTrafficEstimate? {
        guard let location = arrival.vehicleLocation,
              let stop = IntercampusCatalog.stop(id: arrival.stopId)
        else { return nil }

        do {
            let sample = try await fetcher.fetchEstimate(
                from: (latitude: location.latitude, longitude: location.longitude),
                to: (latitude: stop.latitude, longitude: stop.longitude),
                departingAt: now
            )
            guard let sample else {
                cache[cacheKey] = CacheEntry(estimate: nil, expiresAt: now.addingTimeInterval(failureTTL))
                return nil
            }
            let estimate = IntercampusTrafficEstimate(
                generatedAt: now,
                sourceArrivalAt: arrival.arrivalAt,
                arrivalAt: now.addingTimeInterval(sample.travelTime),
                travelTime: sample.travelTime,
                distanceMeters: sample.distanceMeters
            )
            cache[cacheKey] = CacheEntry(estimate: estimate, expiresAt: now.addingTimeInterval(estimateTTL))
            return estimate
        } catch {
            return nil
        }
    }

    private func pruneCache(now: Date) {
        cache = cache.filter { $0.value.expiresAt > now }
    }

    /// Cache identity is keyed by trip + stop + vehicle, NOT the bus's current
    /// position. The bus moves every refresh, so including position would make
    /// almost every lookup a miss. The TTL handles staleness — once the entry
    /// expires we recompute against the latest position.
    private struct CacheKey: Hashable {
        let tripId: String
        let stopId: String
        let vehicleId: String

        init?(arrival: IntercampusArrival) {
            guard arrival.vehicleLocation != nil else { return nil }
            self.tripId = arrival.tripId
            self.stopId = arrival.stopId
            self.vehicleId = arrival.vehicleLocation?.id ?? arrival.vehicleId ?? arrival.tripId
        }
    }

    private struct CacheEntry {
        let estimate: IntercampusTrafficEstimate?
        let expiresAt: Date
    }
}

struct MapKitIntercampusTrafficETAFetcher: IntercampusTrafficETAFetching {
    func fetchEstimate(
        from origin: (latitude: Double, longitude: Double),
        to destination: (latitude: Double, longitude: Double),
        departingAt: Date
    ) async throws -> IntercampusTrafficETASample? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)
        ))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = departingAt

        guard await MapKitDirectionsLimiter.waitForTurn() else {
            throw CancellationError()
        }

        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first,
                  route.distance.isFinite,
                  route.expectedTravelTime.isFinite,
                  route.expectedTravelTime >= 0,
                  route.expectedTravelTime <= 2 * 60 * 60
            else { return nil }
            return IntercampusTrafficETASample(
                travelTime: route.expectedTravelTime,
                distanceMeters: route.distance
            )
        } catch {
            await MapKitDirectionsLimiter.recordFailure(error)
            return nil
        }
    }
}
