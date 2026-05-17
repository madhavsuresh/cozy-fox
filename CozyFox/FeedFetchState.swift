import Foundation

/// Which upstream feed the dashboard is asking about.
enum TransitFeed: Sendable, Hashable {
    case trains
    case buses
    case metra
    case intercampus
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
    var intercampus: FeedFetchState = .init()

    /// Has this feed responded successfully recently enough that we trust an
    /// empty result for it? Falls back to "fetching" otherwise — we don't
    /// want to show "no upcoming arrivals" off a stale or never-completed
    /// fetch. Window is generous (3× the foreground refresh interval) so a
    /// single missed tick doesn't visibly demote the UI to "Fetching…".
    func hasFreshFetch(for feed: TransitFeed, now: Date = .now, within: TimeInterval = 90) -> Bool {
        let state: FeedFetchState
        switch feed {
        case .trains: state = trains
        case .buses: state = buses
        case .metra: state = metra
        case .intercampus: state = intercampus
        }
        guard let lastSuccessAt = state.lastSuccessAt else { return false }
        return now.timeIntervalSince(lastSuccessAt) < within
    }
}
