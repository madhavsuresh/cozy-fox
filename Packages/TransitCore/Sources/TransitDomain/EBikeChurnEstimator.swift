import Foundation
import TransitModels

/// **Future feature stub.** Estimates the rate at which e-bikes leave a station
/// at a given hour-of-day / weekday, using historical `BikeStation` snapshots.
///
/// The cache schema retains snapshots for 14 days so this can be a pure-data
/// drop later. For now `estimate(...)` returns `nil` — callers should treat
/// "no estimate" as "no badge".
public struct EBikeChurnEstimator: Sendable {
    public struct Estimate: Sendable, Hashable {
        public let stationId: String
        public let depletionPerHour: Double
        /// Confidence band 0-1.
        public let confidence: Double
    }

    public init() {}

    public func estimate(
        stationId: String,
        history: [HistoricalSnapshot],
        at hourOfDay: Int,
        weekday: Int
    ) -> Estimate? {
        // Filter to matching hour/weekday across the 14-day window.
        let matching = history.filter { $0.hourOfDay == hourOfDay && $0.weekday == weekday }
        guard matching.count >= 7 else { return nil }
        // Average per-hour depletion across days — naive first cut.
        let deltas = matching.map { abs($0.endCount - $0.startCount) }
        let avg = Double(deltas.reduce(0, +)) / Double(deltas.count)
        return Estimate(
            stationId: stationId,
            depletionPerHour: avg,
            confidence: min(1.0, Double(matching.count) / 14)
        )
    }
}

public struct HistoricalSnapshot: Sendable, Hashable {
    public let stationId: String
    public let hourOfDay: Int
    public let weekday: Int
    public let startCount: Int
    public let endCount: Int
    public init(stationId: String, hourOfDay: Int, weekday: Int, startCount: Int, endCount: Int) {
        self.stationId = stationId
        self.hourOfDay = hourOfDay
        self.weekday = weekday
        self.startCount = startCount
        self.endCount = endCount
    }
}
