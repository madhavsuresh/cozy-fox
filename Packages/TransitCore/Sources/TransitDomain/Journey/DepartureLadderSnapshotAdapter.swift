import Foundation
import TransitCache
import TransitModels

public struct DepartureLadderSnapshotAdapter: Sendable {
    public init() {}

    /// Pull live train departures for a specific station/line out of a
    /// `TransitSnapshot`. Direction filter is optional — pass `nil` to keep
    /// both directions, which is reasonable for a debug surface.
    public func liveTrainDepartures(
        from snapshot: TransitSnapshot,
        line: LineColor,
        stationId: Int,
        directionCode: String? = nil,
        now: Date = .now
    ) -> [LiveDeparture] {
        snapshot.trainArrivals
            .filter { arrival in
                arrival.line == line
                && arrival.stationId == stationId
                && (directionCode == nil || arrival.directionCode == directionCode)
                && arrival.arrivalAt >= now.addingTimeInterval(-30)
                && !arrival.isFault
            }
            .map { arrival in
                LiveDeparture(
                    arrivalAt: arrival.arrivalAt,
                    isApproaching: arrival.isApproaching,
                    isScheduled: arrival.isScheduled,
                    toneHint: arrival.isApproaching ? .strong : (arrival.isDelayed ? .weak : .normal)
                )
            }
    }

    public func feedState(
        from snapshot: TransitSnapshot,
        now: Date = .now,
        freshnessTtlSeconds: TimeInterval = 90
    ) -> FeedState {
        feedState(fetchedAt: snapshot.trainsFetchedAt, now: now, freshnessTtlSeconds: freshnessTtlSeconds)
    }

    public func feedState(
        fetchedAt: Date?,
        now: Date = .now,
        freshnessTtlSeconds: TimeInterval = 90
    ) -> FeedState {
        guard let fetchedAt else { return .missing }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return .fresh }
        return age <= freshnessTtlSeconds ? .fresh : .stale
    }

    public func liveBusDepartures(
        from snapshot: TransitSnapshot,
        route: String,
        stopId: Int,
        directionLabel: String? = nil,
        now: Date = .now
    ) -> [LiveDeparture] {
        snapshot.busPredictions
            .filter { prediction in
                prediction.route == route
                && prediction.stopId == stopId
                && (directionLabel == nil || prediction.directionName.caseInsensitiveCompare(directionLabel!) == .orderedSame)
                && prediction.arrivalAt >= now.addingTimeInterval(-30)
            }
            .map { prediction in
                LiveDeparture(
                    arrivalAt: prediction.arrivalAt,
                    isApproaching: prediction.isApproaching,
                    isScheduled: false,
                    toneHint: prediction.isApproaching ? .strong : (prediction.isDelayed ? .weak : .normal)
                )
            }
    }

    public func liveMetraDepartures(
        from snapshot: TransitSnapshot,
        routeId: String,
        stationId: String,
        directionId: Int? = nil,
        now: Date = .now
    ) -> [LiveDeparture] {
        snapshot.metraPredictions
            .filter { prediction in
                prediction.routeId == routeId
                && prediction.stationId == stationId
                && !prediction.isCanceled
                && (directionId == nil || prediction.directionId == directionId)
                && prediction.arrivalAt >= now.addingTimeInterval(-30)
            }
            .map { prediction in
                LiveDeparture(
                    arrivalAt: prediction.arrivalAt,
                    isApproaching: false,
                    isScheduled: prediction.isScheduled,
                    toneHint: prediction.isScheduled ? .normal : .strong
                )
            }
    }

    public func liveIntercampusDepartures(
        from snapshot: TransitSnapshot,
        stopId: String,
        direction: IntercampusDirection? = nil,
        now: Date = .now
    ) -> [LiveDeparture] {
        snapshot.intercampusArrivals
            .filter { arrival in
                arrival.stopId == stopId
                && (direction == nil || arrival.direction == direction)
                && arrival.arrivalAt >= now.addingTimeInterval(-30)
            }
            .map { arrival in
                LiveDeparture(
                    arrivalAt: arrival.arrivalAt,
                    isApproaching: false,
                    isScheduled: arrival.timeSource == .schedule,
                    toneHint: arrival.isDelayed ? .weak : .normal
                )
            }
    }

}
