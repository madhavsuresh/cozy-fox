import Foundation

/// "How much time do I have to head to this train?" expressed as a
/// passive bucket suitable for subtle color encoding. Not a nudge —
/// just an ambient signal the dashboard can render with a faint tint
/// for users who choose to look.
///
/// Computed per upcoming arrival as
/// `leaveBy = arrivalAt - walkSeconds`. Each user's `walkSeconds`
/// already runs through the Phase 5 walk-speed correction at the
/// dashboard layer, so this struct is purely time-arithmetic on inputs
/// it doesn't second-guess.
///
/// Returns `nil` when `walkSeconds` is unavailable — the caller should
/// render no color, never a misleading neutral.
public struct DepartureUrgency: Sendable, Hashable {
    public enum Bucket: String, Sendable, Hashable {
        /// `leaveBy` is more than `approachingThreshold` away. "Plenty
        /// of time" — no overlay.
        case comfortable
        /// `leaveBy` is inside `[imminentThreshold, approachingThreshold]`.
        /// "Window is opening." Faint warm tint.
        case approaching
        /// `leaveBy` is inside `[0, imminentThreshold]`. "Last comfortable
        /// moment." Clearer warm tint.
        case imminent
        /// `leaveBy` has passed. Unreachable on the current pace.
        /// Render greyed/strikethrough.
        case missed
    }

    public let bucket: Bucket

    /// Signed seconds from `now` to `leaveBy`. Negative means the leave-by
    /// time has passed. Exposed for callers that want to drive their own
    /// tint scale rather than a bucket; the bucket is the canonical surface.
    public let secondsUntilLeaveBy: TimeInterval

    public init(bucket: Bucket, secondsUntilLeaveBy: TimeInterval) {
        self.bucket = bucket
        self.secondsUntilLeaveBy = secondsUntilLeaveBy
    }

    /// Compute the urgency for a single upcoming arrival.
    ///
    /// - parameters:
    ///   - arrivalAt: When the vehicle is predicted to arrive.
    ///   - walkSeconds: How long it takes the user to walk from their
    ///     current location to the stop. `nil` when MapKit hasn't
    ///     produced a cached entry yet — return `nil` rather than a
    ///     misleading bucket.
    ///   - now: Reference clock.
    ///   - approachingThreshold: Seconds to leave-by below which the
    ///     bucket flips to `.approaching`.
    ///   - imminentThreshold: Seconds to leave-by below which the
    ///     bucket flips to `.imminent`.
    public static func from(
        arrivalAt: Date,
        walkSeconds: TimeInterval?,
        now: Date = .now,
        approachingThreshold: TimeInterval = 10 * 60,
        imminentThreshold: TimeInterval = 2 * 60
    ) -> DepartureUrgency? {
        guard let walkSeconds, walkSeconds >= 0 else { return nil }
        let leaveBy = arrivalAt.addingTimeInterval(-walkSeconds)
        let seconds = leaveBy.timeIntervalSince(now)
        let bucket: Bucket = {
            if seconds < 0 { return .missed }
            if seconds < imminentThreshold { return .imminent }
            if seconds < approachingThreshold { return .approaching }
            return .comfortable
        }()
        return DepartureUrgency(bucket: bucket, secondsUntilLeaveBy: seconds)
    }
}
