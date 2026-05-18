import Foundation
import MapKit
import TransitModels

@MainActor
final class IntercampusTrafficETAResolver {
    private let maxTrafficEstimatesPerRefresh = 4
    private let maxVehiclePositionAge: TimeInterval = 3 * 60
    private let estimateTTL: TimeInterval = 90
    private let failureTTL: TimeInterval = 45

    private var cache: [CacheKey: CacheEntry] = [:]

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

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
        ))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        request.departureDate = now

        let directions = MKDirections(request: request)
        guard await MapKitDirectionsLimiter.waitForTurn() else { return nil }
        do {
            let response = try await directions.calculate()
            guard let route = response.routes.first,
                  route.distance.isFinite,
                  route.expectedTravelTime.isFinite,
                  route.expectedTravelTime >= 0,
                  route.expectedTravelTime <= 2 * 60 * 60
            else {
                cache[cacheKey] = CacheEntry(estimate: nil, expiresAt: now.addingTimeInterval(failureTTL))
                return nil
            }
            let estimate = IntercampusTrafficEstimate(
                generatedAt: now,
                sourceArrivalAt: arrival.arrivalAt,
                scheduledArrivalAt: arrival.scheduledArrivalAt,
                arrivalAt: now.addingTimeInterval(route.expectedTravelTime),
                travelTime: route.expectedTravelTime,
                distanceMeters: route.distance
            )
            cache[cacheKey] = CacheEntry(estimate: estimate, expiresAt: now.addingTimeInterval(estimateTTL))
            return estimate
        } catch {
            await MapKitDirectionsLimiter.recordFailure(error)
            cache[cacheKey] = CacheEntry(estimate: nil, expiresAt: now.addingTimeInterval(failureTTL))
            return nil
        }
    }

    private func pruneCache(now: Date) {
        cache = cache.filter { $0.value.expiresAt > now }
    }

    private struct CacheKey: Hashable {
        let tripId: String
        let stopId: String
        let vehicleId: String
        let latitudeBucket: Int
        let longitudeBucket: Int

        init?(arrival: IntercampusArrival) {
            guard let location = arrival.vehicleLocation else { return nil }
            self.tripId = arrival.tripId
            self.stopId = arrival.stopId
            self.vehicleId = location.id ?? arrival.vehicleId ?? arrival.tripId
            self.latitudeBucket = Int((location.latitude * 10_000).rounded())
            self.longitudeBucket = Int((location.longitude * 10_000).rounded())
        }
    }

    private struct CacheEntry {
        let estimate: IntercampusTrafficEstimate?
        let expiresAt: Date
    }
}
