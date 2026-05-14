import Foundation

// MARK: - BiasCellKey

/// Stratification key for the arrival-bias store. Each cell holds a running
/// estimate of "API-said vs reality" for a specific service window: a given
/// line at a given stop, in a given direction, in a particular weekday/hour
/// bucket and season. Keeping winter and summer separate matters because
/// winter slowdowns shouldn't pollute summer baselines, and vice versa.
public struct BiasCellKey: Hashable, Codable, Sendable {
    public let line: String
    public let stopId: String
    public let direction: String
    public let hourClass: HourClass
    public let weekdayClass: WeekdayClass
    public let season: Season

    public init(
        line: String,
        stopId: String,
        direction: String,
        hourClass: HourClass,
        weekdayClass: WeekdayClass,
        season: Season
    ) {
        self.line = line
        self.stopId = stopId
        self.direction = direction
        self.hourClass = hourClass
        self.weekdayClass = weekdayClass
        self.season = season
    }

    /// Convenience constructor that derives the time-of-day buckets from a
    /// `Date`. Use this everywhere a call site already has the wall-clock
    /// instant — it keeps the bucketing rules in one place.
    public static func make(
        line: String,
        stopId: String,
        direction: String,
        at date: Date,
        calendar: Calendar = .current
    ) -> BiasCellKey {
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return BiasCellKey(
            line: line,
            stopId: stopId,
            direction: direction,
            hourClass: HourClass.from(hour: hour),
            weekdayClass: WeekdayClass.from(weekday: weekday, hour: hour),
            season: Season.from(date: date, calendar: calendar)
        )
    }
}

// MARK: - BiasCell

/// Welford-style running statistics over the prediction error (in seconds)
/// for one `BiasCellKey`. The convention is:
///
///   delta = predictedArrivalSeconds - observedArrivalSeconds
///
/// So a positive mean means the API tends to be early / the vehicle late
/// for this cell, and a negative mean means the API runs late.
public struct BiasCell: Codable, Sendable, Hashable {
    public var count: Int
    public var mean: Double
    /// Welford's M2 — sum of squared deviations from the running mean.
    public var m2: Double
    public var lastUpdatedAt: Date

    public init(
        count: Int = 0,
        mean: Double = 0,
        m2: Double = 0,
        lastUpdatedAt: Date = .distantPast
    ) {
        self.count = count
        self.mean = mean
        self.m2 = m2
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// Variance with Bessel's correction. Returns `nil` for `count < 2`.
    public var variance: Double? {
        guard count >= 2 else { return nil }
        return m2 / Double(count - 1)
    }

    public var standardDeviation: Double? {
        variance.map { $0.squareRoot() }
    }

    /// Welford's online update. Mutates the cell in place; safe to call on
    /// every sample without re-summing history.
    public mutating func recordSample(_ delta: Double, at date: Date) {
        count += 1
        let delta1 = delta - mean
        mean += delta1 / Double(count)
        let delta2 = delta - mean
        m2 += delta1 * delta2
        // `lastUpdatedAt` should never move backwards even if samples arrive
        // out of order from the maintenance task.
        if date > lastUpdatedAt {
            lastUpdatedAt = date
        }
    }

    /// Exponential decay applied to `count` and `m2` (and therefore to the
    /// implicit "weight" of past samples). The mean is unchanged because in
    /// the steady state we want the *position* of the distribution to
    /// persist; we only want the *confidence* to bleed off so service
    /// pattern changes can take over quickly.
    public mutating func decay(halfLifeDays: Double, now: Date) {
        guard count > 0, halfLifeDays > 0 else { return }
        let elapsedSeconds = now.timeIntervalSince(lastUpdatedAt)
        guard elapsedSeconds > 0 else { return }
        let elapsedDays = elapsedSeconds / 86_400
        let factor = pow(0.5, elapsedDays / halfLifeDays)
        let newCountFloat = Double(count) * factor
        // Clamp to one — a single old sample is the most we can reasonably
        // remember. If decay drops effective count below 0.5 we drop the
        // cell entirely (handled at the store level).
        let newCount = max(0, Int(newCountFloat.rounded()))
        let scale = newCount == 0 ? 0 : Double(newCount) / Double(count)
        count = newCount
        m2 *= scale
        // Keep `lastUpdatedAt` where it is so subsequent decays don't
        // double-discount; new samples will bump it.
    }
}
