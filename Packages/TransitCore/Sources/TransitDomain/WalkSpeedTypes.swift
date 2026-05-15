import Foundation

/// A single observation of how long a real walk took relative to MapKit's
/// `expectedTravelTime` for the same origin/destination pair. The ratio is
/// what drives the per-user multiplicative correction in
/// `WalkingDistanceStore`.
public struct WalkSpeedSample: Sendable, Hashable {
    public let actualSeconds: TimeInterval
    public let expectedSeconds: TimeInterval
    public let recordedAt: Date

    public init(actualSeconds: TimeInterval, expectedSeconds: TimeInterval, recordedAt: Date) {
        self.actualSeconds = actualSeconds
        self.expectedSeconds = expectedSeconds
        self.recordedAt = recordedAt
    }

    /// `actualSeconds / expectedSeconds`. >1 means the user is slower than
    /// MapKit's default walking pace; <1 means faster. Defaults to 1.0 when
    /// `expectedSeconds` is non-positive (defensive — shouldn't happen for
    /// real MapKit responses).
    public var ratio: Double {
        guard expectedSeconds > 0 else { return 1.0 }
        return actualSeconds / expectedSeconds
    }
}

/// Welford running stats over `WalkSpeedSample.ratio` values. The mean is
/// the user's persistent multiplicative correction; `count` gates whether
/// callers should trust it.
public struct WalkSpeedEstimate: Codable, Sendable, Hashable {
    public var count: Int
    public var mean: Double
    public var m2: Double

    public init(count: Int = 0, mean: Double = 1.0, m2: Double = 0) {
        self.count = count
        self.mean = mean
        self.m2 = m2
    }

    /// Default state: mean = 1.0 (a no-op correction if the gate were
    /// lifted), zero samples, m2 = 0.
    public static let empty = WalkSpeedEstimate()

    /// Returns the running-mean ratio iff `count >= minSamples`. Callers
    /// should treat nil as "no correction — return MapKit's number as-is."
    public func confidentRatio(minSamples: Int = 5) -> Double? {
        guard count >= minSamples else { return nil }
        return mean
    }

    /// Welford online update. Reference:
    /// https://en.wikipedia.org/wiki/Algorithms_for_calculating_variance#Welford's_online_algorithm
    /// `recordedAt` is not used by the algorithm; it's accepted on the
    /// caller side as a memory aid that samples carry timestamps.
    public mutating func recordSample(ratio: Double, at: Date) {
        _ = at
        count += 1
        let delta = ratio - mean
        mean += delta / Double(count)
        let delta2 = ratio - mean
        m2 += delta * delta2
    }
}
