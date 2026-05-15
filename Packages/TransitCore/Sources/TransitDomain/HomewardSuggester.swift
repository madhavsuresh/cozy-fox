import Foundation
import TransitModels

/// Decides when the dashboard should surface a "head home" tile —
/// a quiet, dismissible card that pre-computes a route home from the
/// user's current location. The intended UX moment is "you're out
/// somewhere in the city, want to wind your way home?"
///
/// Pure / deterministic given inputs. Side effects (rendering,
/// dismissal tracking, route planning) live on the caller.
///
/// Gates, ANDed:
/// 1. Home anchor must be set — without a `home` to route to, there's
///    nothing to suggest.
/// 2. Current context must be `.elsewhere` — not `.atHome` and not
///    `.atWork`. Headed-home is meaningless from inside either anchor.
/// 3. User has been `.elsewhere` long enough to look like an outing,
///    not a coffee run. `minimumElsewhereDurationMinutes` defaults
///    to 30 — short enough that a typical evening out qualifies,
///    long enough that a lunch errand doesn't.
/// 4. Either the current local hour is past `eveningHourThreshold`
///    (default 17, i.e. 5 PM) OR the current weekday/hour matches the
///    user's typical "left work toward home" departure window (from
///    `MobilityProfileSummary.departureWindow(source: .exitedWork,
///    direction: .toHome)`). This second branch picks up users who
///    leave work at e.g. 14:00 reliably.
/// 5. Suggestion has not been dismissed recently (caller-tracked
///    `suppressedUntil`).
public struct HomewardSuggester: Sendable {
    public init() {}

    public func shouldSurface(
        context: CommuteContext,
        elsewhereSince: Date?,
        anchors: CommuteAnchors,
        profile: MobilityProfile,
        now: Date = .now,
        suppressedUntil: Date? = nil,
        minimumElsewhereDurationMinutes: Int = 30,
        eveningHourThreshold: Int = 17,
        calendar: Calendar = .current
    ) -> Bool {
        // Gate 1: home anchor required.
        guard anchors.home != nil else { return false }
        // Gate 2: currently elsewhere.
        guard context == .elsewhere else { return false }
        // Gate 3: been elsewhere long enough.
        guard let elsewhereSince else { return false }
        let elapsedMinutes = now.timeIntervalSince(elsewhereSince) / 60
        guard elapsedMinutes >= Double(minimumElsewhereDurationMinutes) else { return false }
        // Gate 4: evening OR matches the typical back-home window.
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let isEvening = hour >= eveningHourThreshold
        let typicalBackHome = profile.summary.departureWindow(
            source: .exitedWork,
            direction: .toHome
        )
        let inTypicalWindow = typicalBackHome?.matchesWindow(
            weekday: weekday,
            hour: hour,
            hourWindow: 2,
            minSamples: 2
        ) ?? false
        guard isEvening || inTypicalWindow else { return false }
        // Gate 5: not suppressed.
        if let suppressedUntil, now < suppressedUntil { return false }
        return true
    }
}
