import Foundation
import MapKit
import TransitDomain
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
            guard let plan = legPlan(for: arrival) else { continue }
            let key = CacheKey(arrival: arrival, plan: plan)
            if let cached = cache[key], cached.expiresAt > now {
                if let estimate = cached.estimate {
                    adjustedById[arrival.id] = arrival.applyingTrafficEstimate(estimate)
                }
                continue
            }
            guard newRequestCount < maxTrafficEstimatesPerRefresh else { continue }
            newRequestCount += 1

            let estimate = await fetchTrafficEstimate(
                for: arrival,
                plan: plan,
                cacheKey: key,
                now: now
            )
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

    /// Plan a per-leg ETA: drive from the bus's current GPS to the next stop it must service
    /// on this trip, then ride the schedule from there through every intermediate stop to the
    /// user's target. MapKit alone would route point-to-point and skip the intermediate dwells,
    /// which is how a Mudd-bound southbound shuttle could show ~5 min when it's actually ~30 min
    /// out behind Sherman/Foster/Sheridan stops.
    private func legPlan(for arrival: IntercampusArrival) -> LegPlan? {
        guard let location = arrival.vehicleLocation,
              let targetStop = IntercampusCatalog.stop(id: arrival.stopId)
        else { return nil }

        guard let tripStops = IntercampusCatalog.tripStops(forTrip: arrival.tripId),
              let targetEntry = tripStops.first(where: { $0.stopId == arrival.stopId })
        else {
            // No catalog trip — degrade to a single-leg MapKit route to the target stop.
            return LegPlan(nextStop: targetStop, scheduledRemainingSeconds: 0)
        }

        let upstream = tripStops.filter { $0.sequence <= targetEntry.sequence }
        let stopsWithCoords = upstream.compactMap { entry -> (entry: IntercampusTripStop, stop: IntercampusStop)? in
            guard let stop = IntercampusCatalog.stop(id: entry.stopId) else { return nil }
            return (entry, stop)
        }
        let closest = stopsWithCoords.min { lhs, rhs in
            let lhsDist = Distance.meters(
                from: (location.latitude, location.longitude),
                to: (lhs.stop.latitude, lhs.stop.longitude)
            )
            let rhsDist = Distance.meters(
                from: (location.latitude, location.longitude),
                to: (rhs.stop.latitude, rhs.stop.longitude)
            )
            return lhsDist < rhsDist
        }
        guard let pivot = closest else {
            return LegPlan(nextStop: targetStop, scheduledRemainingSeconds: 0)
        }

        let remainingSeconds: TimeInterval
        if pivot.entry.stopId == arrival.stopId {
            remainingSeconds = 0
        } else {
            remainingSeconds = IntercampusCatalog.scheduledRemainingSeconds(
                tripId: arrival.tripId,
                from: pivot.entry.stopId,
                to: arrival.stopId
            ) ?? TimeInterval(max(0, targetEntry.arrivalSeconds - pivot.entry.departureSeconds))
        }

        return LegPlan(nextStop: pivot.stop, scheduledRemainingSeconds: remainingSeconds)
    }

    private func fetchTrafficEstimate(
        for arrival: IntercampusArrival,
        plan: LegPlan,
        cacheKey: CacheKey,
        now: Date
    ) async -> IntercampusTrafficEstimate? {
        guard let location = arrival.vehicleLocation else { return nil }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        ))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: plan.nextStop.latitude, longitude: plan.nextStop.longitude)
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
            let totalTravel = route.expectedTravelTime + plan.scheduledRemainingSeconds
            guard totalTravel <= 2 * 60 * 60 else {
                cache[cacheKey] = CacheEntry(estimate: nil, expiresAt: now.addingTimeInterval(failureTTL))
                return nil
            }
            let estimate = IntercampusTrafficEstimate(
                generatedAt: now,
                sourceArrivalAt: arrival.arrivalAt,
                scheduledArrivalAt: arrival.scheduledArrivalAt,
                arrivalAt: now.addingTimeInterval(totalTravel),
                travelTime: totalTravel,
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

    private struct LegPlan {
        let nextStop: IntercampusStop
        let scheduledRemainingSeconds: TimeInterval
    }

    private struct CacheKey: Hashable {
        let tripId: String
        let targetStopId: String
        let nextStopId: String
        let vehicleId: String
        let latitudeBucket: Int
        let longitudeBucket: Int

        init(arrival: IntercampusArrival, plan: LegPlan) {
            let location = arrival.vehicleLocation
            self.tripId = arrival.tripId
            self.targetStopId = arrival.stopId
            self.nextStopId = plan.nextStop.id
            self.vehicleId = location?.id ?? arrival.vehicleId ?? arrival.tripId
            self.latitudeBucket = Int(((location?.latitude ?? 0) * 10_000).rounded())
            self.longitudeBucket = Int(((location?.longitude ?? 0) * 10_000).rounded())
        }
    }

    private struct CacheEntry {
        let estimate: IntercampusTrafficEstimate?
        let expiresAt: Date
    }
}
