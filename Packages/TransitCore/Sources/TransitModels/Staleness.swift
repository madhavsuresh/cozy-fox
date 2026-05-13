import Foundation

/// How fresh a piece of cached data is. The widget shows a soft indicator when
/// data is stale rather than failing.
public struct Staleness: Codable, Sendable, Hashable {
    public let fetchedAt: Date
    public let ttl: TimeInterval

    public init(fetchedAt: Date, ttl: TimeInterval) {
        self.fetchedAt = fetchedAt
        self.ttl = ttl
    }

    public func isStale(at moment: Date = .now) -> Bool {
        moment.timeIntervalSince(fetchedAt) > ttl
    }

    public func ageSeconds(at moment: Date = .now) -> TimeInterval {
        moment.timeIntervalSince(fetchedAt)
    }
}
