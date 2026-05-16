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
        guard let fetchedAt = snapshot.trainsFetchedAt else { return .missing }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 { return .fresh }
        return age <= freshnessTtlSeconds ? .fresh : .stale
    }
}
