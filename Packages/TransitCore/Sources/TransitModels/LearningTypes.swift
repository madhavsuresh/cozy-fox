import Foundation

// MARK: - AnchorID

/// Identifier for a place the on-device learning layer treats as a stable
/// "anchor" — somewhere the user visits often enough that we want to model
/// transitions between it and other anchors. Phase 0 simply persists these
/// alongside the weekly histograms; later phases will use them as Markov
/// states for next-anchor prediction.
///
/// The cases mirror the kinds of locations the rest of the app already
/// reasons about (Home/Work anchors, L stations, bus stops, bucketed
/// coordinates) so downstream consumers can map directly from existing
/// `MobilityProfile` rows without a separate id-resolution step.
public enum AnchorID: Hashable, Codable, Sendable {
    case home
    case work
    case lStation(stationId: Int)
    case busStop(route: String, stopId: Int)
    case metraStation(stationId: String)
    /// Coordinate bucket — the same 0.0025° grid used by
    /// `MobilityProfile.RouteLocation.bucketed`. Stored as integer cell
    /// coordinates so the key is stable across encodings.
    case bucketed(latCell: Int, lonCell: Int)

    private enum Kind: String, Codable {
        case home, work, lStation, busStop, metraStation, bucketed
    }

    private enum CodingKeys: String, CodingKey {
        case kind, stationId, route, stopId, latCell, lonCell
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .home:
            self = .home
        case .work:
            self = .work
        case .lStation:
            let stationId = try c.decode(Int.self, forKey: .stationId)
            self = .lStation(stationId: stationId)
        case .busStop:
            let route = try c.decode(String.self, forKey: .route)
            let stopId = try c.decode(Int.self, forKey: .stopId)
            self = .busStop(route: route, stopId: stopId)
        case .metraStation:
            let stationId = try c.decode(String.self, forKey: .stationId)
            self = .metraStation(stationId: stationId)
        case .bucketed:
            let lat = try c.decode(Int.self, forKey: .latCell)
            let lon = try c.decode(Int.self, forKey: .lonCell)
            self = .bucketed(latCell: lat, lonCell: lon)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .home:
            try c.encode(Kind.home, forKey: .kind)
        case .work:
            try c.encode(Kind.work, forKey: .kind)
        case let .lStation(stationId):
            try c.encode(Kind.lStation, forKey: .kind)
            try c.encode(stationId, forKey: .stationId)
        case let .busStop(route, stopId):
            try c.encode(Kind.busStop, forKey: .kind)
            try c.encode(route, forKey: .route)
            try c.encode(stopId, forKey: .stopId)
        case let .metraStation(stationId):
            try c.encode(Kind.metraStation, forKey: .kind)
            try c.encode(stationId, forKey: .stationId)
        case let .bucketed(latCell, lonCell):
            try c.encode(Kind.bucketed, forKey: .kind)
            try c.encode(latCell, forKey: .latCell)
            try c.encode(lonCell, forKey: .lonCell)
        }
    }

    /// Bucket a coordinate into a stable `AnchorID.bucketed(...)` value using
    /// the same 0.0025° grid as `MobilityProfile.RouteLocation.bucketed`. We
    /// store integer cell indices so dictionary keys don't depend on
    /// floating-point quirks.
    public static func bucketed(
        latitude: Double,
        longitude: Double,
        cellDegrees: Double = 0.0025
    ) -> AnchorID {
        let scale = 1 / cellDegrees
        return .bucketed(
            latCell: Int((latitude * scale).rounded()),
            lonCell: Int((longitude * scale).rounded())
        )
    }
}

// MARK: - HourClass / WeekdayClass / Season

/// Bin a wall-clock hour into one of six service-pattern buckets. Boundaries
/// match how CTA publishes its day-part service patterns.
public enum HourClass: String, Codable, Sendable, Hashable, CaseIterable {
    case earlyMorning
    case amPeak
    case midday
    case pmPeak
    case evening
    case late

    /// 0–5 early; 6–9 am peak; 10–14 midday; 15–18 pm peak;
    /// 19–22 evening; 23 late. AM peak starts at 6 to match CTA's published
    /// weekday peak window (6–9 AM and 3–6 PM).
    public static func from(hour: Int) -> HourClass {
        switch hour {
        case 0...5: .earlyMorning
        case 6...9: .amPeak
        case 10...14: .midday
        case 15...18: .pmPeak
        case 19...22: .evening
        default: .late
        }
    }
}

/// Weekday × hour classification. Used as a stratification key for the bias
/// store so service-pattern changes (Saturday schedule vs weekday rush) don't
/// pollute each other's means.
public enum WeekdayClass: String, Codable, Sendable, Hashable, CaseIterable {
    case weekdayPeak
    case weekdayOffpeak
    case weekend

    /// `weekday` follows `Calendar.component(.weekday, …)` — Sunday = 1,
    /// Saturday = 7. `hour` is 0...23.
    public static func from(weekday: Int, hour: Int) -> WeekdayClass {
        let isWeekend = (weekday == 1 || weekday == 7)
        if isWeekend { return .weekend }
        // CTA's published peak windows are 6–9 AM and 3–6 PM weekdays.
        if (6...9).contains(hour) || (15...18).contains(hour) {
            return .weekdayPeak
        }
        return .weekdayOffpeak
    }
}

/// Meteorological season buckets — winter starts December 1, etc. Used so
/// arrival-bias cells can separate winter slowdowns from summer baselines.
public enum Season: String, Codable, Sendable, Hashable, CaseIterable {
    case winter
    case spring
    case summer
    case fall

    public static func from(month: Int) -> Season {
        switch month {
        case 12, 1, 2: .winter
        case 3, 4, 5: .spring
        case 6, 7, 8: .summer
        default: .fall
        }
    }

    public static func from(date: Date, calendar: Calendar = .current) -> Season {
        from(month: calendar.component(.month, from: date))
    }
}

// MARK: - HourOfWeek helper

public enum HourOfWeek {
    /// Maps a `(weekday, hour)` pair to an integer 0...167. Monday-anchored:
    /// Monday 00:00 → 0, Tuesday 00:00 → 24, …, Sunday 23:00 → 167.
    ///
    /// `weekday` follows `Calendar.component(.weekday, …)` — Sunday = 1,
    /// Saturday = 7 — so we remap to Mon-first to keep the ISO-week histogram
    /// indexing consistent.
    public static func index(weekday: Int, hour: Int) -> Int {
        // Sunday=1...Saturday=7 → Mon=0...Sun=6
        let monAnchored = ((weekday - 2) + 7) % 7
        let h = max(0, min(23, hour))
        return monAnchored * 24 + h
    }
}
