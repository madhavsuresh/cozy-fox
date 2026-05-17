import Foundation

/// Discrete horizon bucket for binning prediction residuals. CTA's `prdctdn`
/// values up to a few minutes are riskier than 15-minute-out estimates;
/// keeping per-bucket residuals lets us shrink intervals on the bins where
/// we have data without distorting the rest.
public enum BusHorizonBucket: String, Codable, Sendable, Hashable, CaseIterable {
    case under2min = "0-2m"
    case under5min = "2-5m"
    case under10min = "5-10m"
    case under20min = "10-20m"
    case under1hour = "20-60m"
    case over1hour = "60m+"

    /// Map a positive horizon (seconds between snapshot and predicted
    /// arrival) into a bucket. Negative or zero horizons clamp to the
    /// shortest bucket — they shouldn't be recorded as residuals, but
    /// defensive default keeps the binner total.
    public static func bucket(for horizonSeconds: Double) -> BusHorizonBucket {
        switch horizonSeconds {
        case ..<120: return .under2min
        case ..<300: return .under5min
        case ..<600: return .under10min
        case ..<1_200: return .under20min
        case ..<3_600: return .under1hour
        default: return .over1hour
        }
    }
}

/// One raw observed residual: how much later/earlier the bus arrived
/// relative to what CTA predicted at snapshot time. Positive means the bus
/// arrived later than CTA said it would — the more common direction.
///
/// Rows are persisted via `CachedBusPredictionResidual` for ~30 days, then
/// rolled into `BusResidualQuantileBin` and (eventually) pruned.
public struct BusPredictionResidual: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let route: String
    public let directionName: String
    public let stopId: Int
    public let vehicleId: String
    /// When CTA first emitted this prediction (its `tmstmp`).
    public let predictedAt: Date
    /// The arrival time CTA's prediction was pointing at.
    public let predictedArrivalAt: Date
    /// When the bus actually crossed the stop (per `ArrivalGrader`'s
    /// crossing inference — phase 1 quality, will get tighter when phase
    /// 3 pdist-crossing confirmations land for the same hook).
    public let confirmedArrivalAt: Date
    public let horizonBucket: BusHorizonBucket
    /// 0...167. Sunday 00:00 = 0; Saturday 23:00 = 167. CTA-local time.
    public let hourOfWeek: Int
    /// `confirmedArrivalAt - predictedArrivalAt`, in seconds. Positive ⇒ bus
    /// was later than CTA said.
    public let residualSeconds: Double

    public init(
        id: UUID = UUID(),
        route: String,
        directionName: String,
        stopId: Int,
        vehicleId: String,
        predictedAt: Date,
        predictedArrivalAt: Date,
        confirmedArrivalAt: Date,
        horizonBucket: BusHorizonBucket,
        hourOfWeek: Int,
        residualSeconds: Double
    ) {
        self.id = id
        self.route = route
        self.directionName = directionName
        self.stopId = stopId
        self.vehicleId = vehicleId
        self.predictedAt = predictedAt
        self.predictedArrivalAt = predictedArrivalAt
        self.confirmedArrivalAt = confirmedArrivalAt
        self.horizonBucket = horizonBucket
        self.hourOfWeek = hourOfWeek
        self.residualSeconds = residualSeconds
    }
}

/// Aggregated residual quantiles for one (route, direction, stop, horizon,
/// hour-of-week) bin. Kept across raw-row pruning so the calibration value
/// persists.
public struct BusResidualQuantileBin: Codable, Sendable, Hashable {
    public let route: String
    public let directionName: String
    public let stopId: Int
    public let horizonBucket: BusHorizonBucket
    public let hourOfWeek: Int
    public let sampleCount: Int
    public let q10Seconds: Double
    public let q50Seconds: Double
    public let q90Seconds: Double
    public let lastUpdated: Date

    public init(
        route: String,
        directionName: String,
        stopId: Int,
        horizonBucket: BusHorizonBucket,
        hourOfWeek: Int,
        sampleCount: Int,
        q10Seconds: Double,
        q50Seconds: Double,
        q90Seconds: Double,
        lastUpdated: Date
    ) {
        self.route = route
        self.directionName = directionName
        self.stopId = stopId
        self.horizonBucket = horizonBucket
        self.hourOfWeek = hourOfWeek
        self.sampleCount = sampleCount
        self.q10Seconds = q10Seconds
        self.q50Seconds = q50Seconds
        self.q90Seconds = q90Seconds
        self.lastUpdated = lastUpdated
    }

    /// Composite key for SwiftData uniqueness — same shape callers can use
    /// for map lookups in memory.
    public var key: String {
        "\(route)|\(directionName)|\(stopId)|\(horizonBucket.rawValue)|\(hourOfWeek)"
    }
}

/// Compute hour-of-week from a Chicago-local calendar. Sunday=0, Monday=1
/// (matching `Calendar.firstWeekday` defaults), hour 0..23.
public enum BusHourOfWeek {
    public static func value(for date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1...7, Sun = 1
        let hour = calendar.component(.hour, from: date)        // 0...23
        return (weekday - 1) * 24 + hour
    }
}
