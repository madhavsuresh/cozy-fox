import Foundation

public struct TimeDistributionSummary: Sendable, Hashable, Codable {
    public let mean: TimeInterval
    public let p50: TimeInterval
    public let p80: TimeInterval
    public let p90: TimeInterval
    public let confidence: Double
    public let sampleCount: Int

    public init(
        mean: TimeInterval,
        p50: TimeInterval,
        p80: TimeInterval,
        p90: TimeInterval,
        confidence: Double,
        sampleCount: Int
    ) {
        self.mean = mean
        self.p50 = p50
        self.p80 = p80
        self.p90 = p90
        self.confidence = max(0, min(1, confidence))
        self.sampleCount = max(0, sampleCount)
    }

    public static let zero = TimeDistributionSummary(
        mean: 0, p50: 0, p80: 0, p90: 0, confidence: 0, sampleCount: 0
    )

    public enum Quantile: Sendable, Hashable, Codable {
        case mean
        case p50
        case p80
        case p90

        public func value(in summary: TimeDistributionSummary) -> TimeInterval {
            switch self {
            case .mean: summary.mean
            case .p50: summary.p50
            case .p80: summary.p80
            case .p90: summary.p90
            }
        }
    }

    public func value(of quantile: Quantile) -> TimeInterval {
        quantile.value(in: self)
    }

    public func asSecondsRange(low: Quantile, high: Quantile) -> ClosedRange<TimeInterval> {
        let lo = value(of: low)
        let hi = value(of: high)
        if lo <= hi { return lo...hi }
        return hi...lo
    }

    /// Empirical quantile constructor over a list of duration samples.
    /// Uses the textbook nearest-rank method so tests are easy to write
    /// deterministically. Confidence is `min(1, sampleCount / 30)` — calibration
    /// metadata can override later.
    public static func empirical(from samples: [TimeInterval]) -> TimeDistributionSummary {
        let cleaned = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !cleaned.isEmpty else { return .zero }
        let count = cleaned.count
        let mean = cleaned.reduce(0, +) / Double(count)
        let confidence = min(1.0, Double(count) / 30.0)
        return TimeDistributionSummary(
            mean: mean,
            p50: nearestRankQuantile(cleaned, p: 0.50),
            p80: nearestRankQuantile(cleaned, p: 0.80),
            p90: nearestRankQuantile(cleaned, p: 0.90),
            confidence: confidence,
            sampleCount: count
        )
    }

    /// Construct a summary from an analytic Gaussian-like model — useful for
    /// kernels that don't have empirical samples yet but want to emit
    /// quantiles directly.
    public static func analytic(
        mean: TimeInterval,
        standardDeviation: TimeInterval,
        confidence: Double,
        sampleCount: Int = 0
    ) -> TimeDistributionSummary {
        let sigma = max(0, standardDeviation)
        return TimeDistributionSummary(
            mean: max(0, mean),
            p50: max(0, mean),
            p80: max(0, mean + 0.8416 * sigma),
            p90: max(0, mean + 1.2816 * sigma),
            confidence: confidence,
            sampleCount: sampleCount
        )
    }
}

private func nearestRankQuantile(_ sorted: [TimeInterval], p: Double) -> TimeInterval {
    if sorted.isEmpty { return 0 }
    let n = sorted.count
    let rank = max(1, Int((p * Double(n)).rounded(.up)))
    let clamped = min(rank, n)
    return sorted[clamped - 1]
}
