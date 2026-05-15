import Foundation
import TransitModels

/// Late-night safety signal derived from the current arrivals snapshot.
/// Answers "is this likely the last viable train for the next while?"
/// without any persistent historical store — the CTA API stops
/// reporting arrivals when service is winding down for the night, so
/// the *absence* of further predictions is itself the signal.
///
/// Pure function. The caller filters `arrivals` to whatever subset is
/// relevant (typically a single (line, stationId, direction) the
/// user takes home) and asks for a warning. The detector applies a
/// conservative gate so it stays silent during normal service.
///
/// Three gates, ANDed:
/// 1. Local hour ≥ `lateNightHour` (default 22 = 10 PM). Daytime
///    snapshots that happen to show few arrivals are between rush
///    hours, not service-ending.
/// 2. At most `consideredLastThreshold` upcoming arrivals in the
///    snapshot (default 3). Normal mid-day windows show 4-8
///    arrivals; service-ending windows trail off.
/// 3. The latest upcoming arrival is within `warningWindow` (default
///    30 min). Past that, it's just sparse late-night service, not
///    a last-call moment.
///
/// Returns `.warning(minutesUntilLast:)` when all gates pass, else
/// nil.
public struct LastTrainSafety: Sendable {
    public struct Warning: Sendable, Hashable {
        public let minutesUntilLast: Int
    }

    public init() {}

    public func warning(
        forArrivals arrivals: [Arrival],
        now: Date = .now,
        lateNightHour: Int = 22,
        warningWindow: TimeInterval = 30 * 60,
        consideredLastThreshold: Int = 3,
        calendar: Calendar = .current
    ) -> Warning? {
        let hour = calendar.component(.hour, from: now)
        guard hour >= lateNightHour else { return nil }

        let upcoming = arrivals
            .filter { $0.arrivalAt > now }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        guard let latest = upcoming.last else { return nil }
        guard upcoming.count <= consideredLastThreshold else { return nil }

        let untilLastSeconds = latest.arrivalAt.timeIntervalSince(now)
        guard untilLastSeconds <= warningWindow else { return nil }

        let minutesUntilLast = max(1, Int((untilLastSeconds / 60).rounded()))
        return Warning(minutesUntilLast: minutesUntilLast)
    }
}
