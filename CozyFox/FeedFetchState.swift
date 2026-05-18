import Foundation

/// Which upstream feed the dashboard is asking about.
enum TransitFeed: Sendable, Hashable {
    case trains
    case buses
    case metra
    case amtrak
    case intercampus
}

/// Identifies a single pinnable thing (station/route/stop) so per-feed
/// state can distinguish "the station the user pinned succeeded" from
/// "a sibling discovery target succeeded." Mirrors the granularity each
/// refresh function actually queries at; finer-grained variants (per
/// platform `stopId`, per Metra direction) collapse to the parent so
/// the UI doesn't need to know which exact CTA query shape the refresh
/// used.
enum TargetFetchKey: Sendable, Hashable {
    /// CTA train station, keyed by `mapId` (station id). Covers both
    /// station-level (`mapId`) and platform-level (`stopId`) queries for
    /// the same station.
    case train(stationId: Int)
    /// CTA bus, keyed by route + stop.
    case bus(route: String, stopId: Int)
    /// Metra, keyed by route + station. Direction is ignored — the
    /// schedule lookup is per (route, station) and we don't surface
    /// direction freshness separately.
    case metra(routeId: String, stationId: String)
    /// Amtrak, keyed by route + station. Direction is ignored for the
    /// same reason as Metra: schedule lookup is per (route, station).
    case amtrak(routeId: String, stationId: String)
    /// Northwestern Intercampus, keyed by stop id.
    case intercampus(stopId: String)
}

/// Per-feed liveness signal so the UI can distinguish "we haven't heard back
/// yet" from "we heard back and there's genuinely nothing." Updated by
/// `RefreshCoordinator` after each per-feed refresh attempt; mirrored onto
/// `AppViewModel.feedFetchStates` for SwiftUI to observe.
struct FeedFetchState: Sendable, Equatable {
    /// Most recent moment at which at least one request for this feed
    /// returned without throwing — including responses that decoded to an
    /// empty array. Nil before the first success.
    var lastSuccessAt: Date?

    /// Number of consecutive failed refresh attempts since the last success.
    /// Resets to zero on any success. Used purely for diagnostics today.
    var consecutiveFailures: Int = 0
}

/// Snapshot of fetch state across every feed the dashboard surfaces.
struct FeedFetchStates: Sendable, Equatable {
    var trains: FeedFetchState = .init()
    var buses: FeedFetchState = .init()
    var metra: FeedFetchState = .init()
    var amtrak: FeedFetchState = .init()
    var intercampus: FeedFetchState = .init()

    /// Per-target `lastSuccessAt` map. This is the source of truth for the
    /// dashboard's empty-state copy and the staleness affordance — the
    /// feed-level rollups above are kept for diagnostics. Keying per target
    /// matters because one stop's fetch can fail while a sibling target
    /// succeeds, and the user's pinned stop must reflect its own reality,
    /// not the aggregate.
    var targetSuccesses: [TargetFetchKey: Date] = [:]

    /// Default freshness window — 3× the foreground refresh interval. A
    /// single missed tick (30 s) doesn't demote a card to "Fetching…";
    /// two consecutive misses do.
    static let defaultFreshnessWindow: TimeInterval = 90

    /// Has this feed responded successfully recently enough that we trust an
    /// empty result for it? Falls back to "fetching" otherwise — we don't
    /// want to show "no upcoming arrivals" off a stale or never-completed
    /// fetch. Use the per-target form `hasFreshFetch(forTarget:)` whenever
    /// possible; this rollup is only correct for surfaces that don't know
    /// which specific target they're rendering (e.g. cross-feed sections).
    func hasFreshFetch(
        for feed: TransitFeed,
        now: Date = .now,
        within: TimeInterval = defaultFreshnessWindow
    ) -> Bool {
        let state: FeedFetchState
        switch feed {
        case .trains: state = trains
        case .buses: state = buses
        case .metra: state = metra
        case .amtrak: state = amtrak
        case .intercampus: state = intercampus
        }
        guard let lastSuccessAt = state.lastSuccessAt else { return false }
        return now.timeIntervalSince(lastSuccessAt) < within
    }

    /// Has this specific pinned target responded recently? This is what the
    /// pinned-card empty-state copy and staleness indicator should use —
    /// a sibling target's success can't drag the feed-level rollup forward
    /// and let the UI lie about an unanswered stop.
    func hasFreshFetch(
        forTarget key: TargetFetchKey,
        now: Date = .now,
        within: TimeInterval = defaultFreshnessWindow
    ) -> Bool {
        guard let lastSuccessAt = targetSuccesses[key] else { return false }
        return now.timeIntervalSince(lastSuccessAt) < within
    }

    /// Age of the last successful fetch for `key`, in seconds. Nil if no
    /// successful fetch has been recorded yet. Drives the staleness
    /// affordance on pinned cards.
    func age(forTarget key: TargetFetchKey, now: Date = .now) -> TimeInterval? {
        guard let lastSuccessAt = targetSuccesses[key] else { return nil }
        return max(0, now.timeIntervalSince(lastSuccessAt))
    }

    /// Record that `key` got a clean response at `now`. Idempotent.
    mutating func recordSuccess(_ key: TargetFetchKey, at now: Date = .now) {
        targetSuccesses[key] = now
    }

    /// Record successes for multiple keys in one shot — useful for the
    /// intercampus client which answers all requested stop ids in a single
    /// request, so success means every stop in the batch is fresh.
    mutating func recordSuccesses(_ keys: some Sequence<TargetFetchKey>, at now: Date = .now) {
        for key in keys {
            targetSuccesses[key] = now
        }
    }
}

/// Bucketed liveness state for the staleness affordance on pinned cards.
/// Thresholds tuned to the upstream cadence: CTA Train/Bus Tracker
/// republishes predictions about every 30 s, so "fresh" means we caught the
/// upstream within one of its update windows. After missing two upstream
/// windows (≥ 60 s) the card visibly ages; after five (≥ 5 min) we treat
/// the data as actively stale.
enum Staleness: Sendable, Equatable {
    /// No successful fetch yet for this target.
    case unknown
    /// Younger than the first bucket boundary — data is effectively live.
    case live
    /// Within two upstream windows. Still trustworthy, just no longer brand-new.
    case current(seconds: Int)
    /// Past two upstream windows but under five minutes — showing the age in
    /// minutes makes the staleness visible without being alarming.
    case aging(minutes: Int)
    /// Five minutes or more — actively stale; the user should suspect
    /// network/upstream trouble.
    case stale(minutes: Int)

    static let liveCutoff: TimeInterval = 30        // ≤ one upstream window
    static let agingCutoff: TimeInterval = 60       // ≤ two upstream windows
    static let staleCutoff: TimeInterval = 5 * 60   // 5 min

    static func from(age: TimeInterval?) -> Staleness {
        guard let age else { return .unknown }
        let bounded = max(0, age)
        if bounded < liveCutoff { return .live }
        if bounded < agingCutoff { return .current(seconds: Int(bounded.rounded())) }
        if bounded < staleCutoff { return .aging(minutes: max(1, Int((bounded / 60).rounded()))) }
        return .stale(minutes: max(5, Int((bounded / 60).rounded())))
    }

    /// Compact label for the indicator. Glanceable.
    var label: String {
        switch self {
        case .unknown: return "—"
        case .live: return "live"
        case .current(let seconds): return "\(seconds)s"
        case .aging(let minutes): return "\(minutes)m"
        case .stale(let minutes): return "\(minutes)m"
        }
    }

    /// VoiceOver text — more explicit than the visual label.
    var accessibilityLabel: String {
        switch self {
        case .unknown: return "Live data not yet received"
        case .live: return "Live, just refreshed"
        case .current(let seconds): return "Refreshed \(seconds) seconds ago"
        case .aging(let minutes): return "Refreshed \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        case .stale(let minutes): return "Stale: last refreshed \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
    }

    /// Is this the "fully fresh" bucket? Used by the indicator to decide
    /// whether to pulse the dot or hold it steady.
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Is this an "actively concerning" state the indicator should
    /// emphasize?
    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }
}
