import Foundation

public enum IntercampusDirection: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case northbound
    case southbound

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .northbound: "Northbound"
        case .southbound: "Southbound"
        }
    }
}

public struct IntercampusRoute: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let direction: IntercampusDirection
    public let longName: String
    public let destinationName: String

    public init(
        id: String,
        direction: IntercampusDirection,
        longName: String,
        destinationName: String
    ) {
        self.id = id
        self.direction = direction
        self.longName = longName
        self.destinationName = destinationName
    }
}

public struct IntercampusStop: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let servedDirections: [IntercampusDirection]

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        servedDirections: [IntercampusDirection]
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.servedDirections = servedDirections
    }
}

public enum IntercampusArrivalTimeSource: String, Codable, Sendable, Hashable {
    /// Time came from TripShot realtime updates, backed by the live vehicle map.
    case liveMap
    /// Time came from the static GTFS schedule because no realtime stop update
    /// was available for this trip/stop.
    case schedule

    public var label: String {
        switch self {
        case .liveMap: "Live map"
        case .schedule: "Schedule"
        }
    }
}

public struct IntercampusArrival: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let routeId: String
    public let direction: IntercampusDirection
    public let tripId: String
    public let vehicleId: String?
    public let vehicleLabel: String?
    public let stopId: String
    public let stopName: String
    public let destinationName: String
    public let generatedAt: Date
    public let arrivalAt: Date
    public let delaySeconds: Int?
    public let isDelayed: Bool
    public let timeSource: IntercampusArrivalTimeSource

    public init(
        id: String,
        routeId: String,
        direction: IntercampusDirection,
        tripId: String,
        vehicleId: String?,
        vehicleLabel: String?,
        stopId: String,
        stopName: String,
        destinationName: String,
        generatedAt: Date,
        arrivalAt: Date,
        delaySeconds: Int?,
        isDelayed: Bool,
        timeSource: IntercampusArrivalTimeSource = .liveMap
    ) {
        self.id = id
        self.routeId = routeId
        self.direction = direction
        self.tripId = tripId
        self.vehicleId = vehicleId
        self.vehicleLabel = vehicleLabel
        self.stopId = stopId
        self.stopName = stopName
        self.destinationName = destinationName
        self.generatedAt = generatedAt
        self.arrivalAt = arrivalAt
        self.delaySeconds = delaySeconds
        self.isDelayed = isDelayed
        self.timeSource = timeSource
    }

    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }
}

public enum IntercampusCatalog {
    public static var routes: [IntercampusRoute] { IntercampusCatalogStore.shared.routes }
    public static var all: [IntercampusStop] { IntercampusCatalogStore.shared.stops }
    public static var allRouteIds: [String] { IntercampusCatalogStore.shared.routes.map(\.id) }

    public static func route(id: String) -> IntercampusRoute? {
        IntercampusCatalogStore.shared.routeById[id]
    }

    public static func route(for direction: IntercampusDirection) -> IntercampusRoute? {
        IntercampusCatalogStore.shared.routeByDirection[direction]
    }

    public static func direction(routeId: String) -> IntercampusDirection? {
        route(id: routeId)?.direction
    }

    public static func routeId(forTrip tripId: String) -> String? {
        IntercampusCatalogStore.shared.tripById[tripId]?.routeId
    }

    public static func route(forTrip tripId: String) -> IntercampusRoute? {
        routeId(forTrip: tripId).flatMap(route(id:))
    }

    public static func destinationName(for direction: IntercampusDirection) -> String {
        route(for: direction)?.destinationName ?? direction.label
    }

    public static func stop(id: String) -> IntercampusStop? {
        IntercampusCatalogStore.shared.stopById[id]
    }

    public static func stops(for direction: IntercampusDirection) -> [IntercampusStop] {
        IntercampusCatalogStore.shared.stopsByDirection[direction] ?? []
    }

    public static func scheduledArrivals(
        stopIds: Set<String>?,
        after now: Date,
        generatedAt: Date,
        lookaheadDays: Int = 2
    ) -> [IntercampusArrival] {
        IntercampusCatalogStore.shared.scheduledArrivals(
            stopIds: stopIds,
            after: now,
            generatedAt: generatedAt,
            lookaheadDays: lookaheadDays
        )
    }
}

private struct IntercampusCatalogStore: Sendable {
    static let shared = IntercampusCatalogStore()

    let routes: [IntercampusRoute]
    let stops: [IntercampusStop]
    let routeById: [String: IntercampusRoute]
    let routeByDirection: [IntercampusDirection: IntercampusRoute]
    let stopById: [String: IntercampusStop]
    let stopsByDirection: [IntercampusDirection: [IntercampusStop]]
    let tripById: [String: ScheduledTrip]
    let stopTimesByStopId: [String: [ScheduledStopTime]]
    let calendarByServiceId: [String: ServiceCalendar]
    let calendarDatesByDate: [Int: [ServiceException]]

    init() {
        let resource = Self.loadResource()
        self.routes = resource.routes.compactMap(\.model)
        self.stops = resource.stops.compactMap(\.model)
        self.routeById = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        self.routeByDirection = Dictionary(uniqueKeysWithValues: routes.map { ($0.direction, $0) })
        self.stopById = Dictionary(uniqueKeysWithValues: stops.map { ($0.id, $0) })

        var orderedStops: [IntercampusDirection: [IntercampusStop]] = [:]
        for routeStop in resource.routeStops.compactMap(\.model) {
            guard let direction = routeById[routeStop.routeId]?.direction,
                  let stop = stopById[routeStop.stopId]
            else { continue }
            orderedStops[direction, default: []].append(stop)
        }
        self.stopsByDirection = orderedStops.mapValues { stops in
            var seen: Set<String> = []
            return stops.filter { seen.insert($0.id).inserted }
        }
        self.tripById = Dictionary(uniqueKeysWithValues: resource.trips.compactMap(\.model).map { ($0.id, $0) })

        var stopTimes: [String: [ScheduledStopTime]] = [:]
        for stopTime in resource.stopTimes.compactMap(\.model) {
            guard tripById[stopTime.tripId] != nil,
                  stopById[stopTime.stopId] != nil
            else { continue }
            stopTimes[stopTime.stopId, default: []].append(stopTime)
        }
        self.stopTimesByStopId = stopTimes.mapValues { entries in
            entries.sorted {
                if $0.arrivalSeconds == $1.arrivalSeconds {
                    return $0.tripId < $1.tripId
                }
                return $0.arrivalSeconds < $1.arrivalSeconds
            }
        }
        self.calendarByServiceId = Dictionary(
            uniqueKeysWithValues: resource.calendar.compactMap(\.model).map { ($0.serviceId, $0) }
        )
        self.calendarDatesByDate = Dictionary(grouping: resource.calendarDates.compactMap(\.model), by: \.date)
    }

    func scheduledArrivals(
        stopIds: Set<String>?,
        after now: Date,
        generatedAt: Date,
        lookaheadDays: Int
    ) -> [IntercampusArrival] {
        let serviceDays = Self.serviceDays(around: now, lookaheadDays: lookaheadDays)
        let earliest = now.addingTimeInterval(-120)
        let latest = now.addingTimeInterval(TimeInterval(max(1, lookaheadDays) * 24 * 60 * 60))
        var arrivals: [IntercampusArrival] = []

        for serviceDay in serviceDays {
            let activeServices = activeServiceIds(on: serviceDay)
            guard !activeServices.isEmpty else { continue }

            let candidateStopIds = stopIds.map(Array.init) ?? Array(stopTimesByStopId.keys)
            for stopId in candidateStopIds {
                guard let stop = stopById[stopId] else { continue }
                for stopTime in stopTimesByStopId[stopId] ?? [] {
                    guard let trip = tripById[stopTime.tripId],
                          activeServices.contains(trip.serviceId),
                          let route = routeById[trip.routeId],
                          stop.servedDirections.contains(route.direction)
                    else { continue }

                    let arrivalAt = serviceDay.midnight.addingTimeInterval(TimeInterval(stopTime.arrivalSeconds))
                    guard arrivalAt >= earliest, arrivalAt <= latest else { continue }
                    arrivals.append(IntercampusArrival(
                        id: "intercampus-scheduled-\(trip.id)-\(stop.id)-\(Int(arrivalAt.timeIntervalSince1970))",
                        routeId: route.id,
                        direction: route.direction,
                        tripId: trip.id,
                        vehicleId: nil,
                        vehicleLabel: nil,
                        stopId: stop.id,
                        stopName: stop.name,
                        destinationName: route.destinationName,
                        generatedAt: generatedAt,
                        arrivalAt: arrivalAt,
                        delaySeconds: nil,
                        isDelayed: false,
                        timeSource: .schedule
                    ))
                }
            }
        }

        return arrivals.sorted { $0.arrivalAt < $1.arrivalAt }
    }

    private func activeServiceIds(on serviceDay: ServiceDay) -> Set<String> {
        var active = Set(calendarByServiceId.values.compactMap { calendar in
            calendar.isActive(on: serviceDay) ? calendar.serviceId : nil
        })
        for exception in calendarDatesByDate[serviceDay.yyyymmdd] ?? [] {
            switch exception.exceptionType {
            case 1:
                active.insert(exception.serviceId)
            case 2:
                active.remove(exception.serviceId)
            default:
                break
            }
        }
        return active
    }

    private static func loadResource() -> IntercampusCatalogResource {
        guard let url = Bundle.module.url(forResource: "IntercampusCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(IntercampusCatalogResource.self, from: data)
        else {
            return IntercampusCatalogResource(source: nil, routes: [], stops: [], routeStops: [])
        }
        return decoded
    }

    private static let serviceTimeZone = TimeZone(identifier: "America/Chicago")!

    private static var serviceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = serviceTimeZone
        return calendar
    }

    private static func serviceDays(around now: Date, lookaheadDays: Int) -> [ServiceDay] {
        let calendar = serviceCalendar
        let today = calendar.startOfDay(for: now)
        return (-1...max(0, lookaheadDays)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map {
                ServiceDay(midnight: $0, calendar: calendar)
            }
        }
    }
}

private struct IntercampusCatalogResource: Decodable {
    let source: String?
    let routes: [RouteRow]
    let stops: [StopRow]
    let routeStops: [RouteStopRow]
    let trips: [TripRow]
    let stopTimes: [StopTimeRow]
    let calendar: [CalendarRow]
    let calendarDates: [CalendarDateRow]

    enum CodingKeys: String, CodingKey {
        case source
        case routes
        case stops
        case routeStops
        case trips
        case stopTimes
        case calendar
        case calendarDates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        routes = try c.decodeIfPresent([RouteRow].self, forKey: .routes) ?? []
        stops = try c.decodeIfPresent([StopRow].self, forKey: .stops) ?? []
        routeStops = try c.decodeIfPresent([RouteStopRow].self, forKey: .routeStops) ?? []
        trips = try c.decodeIfPresent([TripRow].self, forKey: .trips) ?? []
        stopTimes = try c.decodeIfPresent([StopTimeRow].self, forKey: .stopTimes) ?? []
        calendar = try c.decodeIfPresent([CalendarRow].self, forKey: .calendar) ?? []
        calendarDates = try c.decodeIfPresent([CalendarDateRow].self, forKey: .calendarDates) ?? []
    }

    init(
        source: String?,
        routes: [RouteRow],
        stops: [StopRow],
        routeStops: [RouteStopRow],
        trips: [TripRow] = [],
        stopTimes: [StopTimeRow] = [],
        calendar: [CalendarRow] = [],
        calendarDates: [CalendarDateRow] = []
    ) {
        self.source = source
        self.routes = routes
        self.stops = stops
        self.routeStops = routeStops
        self.trips = trips
        self.stopTimes = stopTimes
        self.calendar = calendar
        self.calendarDates = calendarDates
    }

    struct RouteRow: Decodable {
        let model: IntercampusRoute?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            guard let direction = IntercampusDirection(rawValue: try c.decode(String.self)) else {
                model = nil
                return
            }
            model = IntercampusRoute(
                id: id,
                direction: direction,
                longName: try c.decode(String.self),
                destinationName: try c.decode(String.self)
            )
        }
    }

    struct StopRow: Decodable {
        let model: IntercampusStop?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            let name = try c.decode(String.self)
            let latitude = try c.decode(Double.self)
            let longitude = try c.decode(Double.self)
            let directions = try c.decode([String].self)
                .compactMap(IntercampusDirection.init(rawValue:))
            guard !directions.isEmpty else {
                model = nil
                return
            }
            model = IntercampusStop(
                id: id,
                name: name,
                latitude: latitude,
                longitude: longitude,
                servedDirections: directions
            )
        }
    }

    struct RouteStopRow: Decodable {
        let model: RouteStop?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = RouteStop(
                routeId: try c.decode(String.self),
                stopId: try c.decode(String.self),
            sequence: try c.decode(Int.self)
            )
        }
    }

    struct TripRow: Decodable {
        let model: ScheduledTrip?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = ScheduledTrip(
                id: try c.decode(String.self),
                routeId: try c.decode(String.self),
                serviceId: try c.decode(String.self)
            )
        }
    }

    struct StopTimeRow: Decodable {
        let model: ScheduledStopTime?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = ScheduledStopTime(
                tripId: try c.decode(String.self),
                stopId: try c.decode(String.self),
                sequence: try c.decode(Int.self),
                arrivalSeconds: try c.decode(Int.self),
                departureSeconds: try c.decode(Int.self)
            )
        }
    }

    struct CalendarRow: Decodable {
        let model: ServiceCalendar?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = ServiceCalendar(
                serviceId: try c.decode(String.self),
                weekdays: try c.decode([Int].self).map { $0 == 1 },
                startDate: try c.decode(Int.self),
                endDate: try c.decode(Int.self)
            )
        }
    }

    struct CalendarDateRow: Decodable {
        let model: ServiceException?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = ServiceException(
                serviceId: try c.decode(String.self),
                date: try c.decode(Int.self),
                exceptionType: try c.decode(Int.self)
            )
        }
    }

    struct RouteStop: Sendable, Hashable {
        let routeId: String
        let stopId: String
        let sequence: Int
    }
}

private struct ScheduledTrip: Sendable, Hashable {
    let id: String
    let routeId: String
    let serviceId: String
}

private struct ScheduledStopTime: Sendable, Hashable {
    let tripId: String
    let stopId: String
    let sequence: Int
    let arrivalSeconds: Int
    let departureSeconds: Int
}

private struct ServiceCalendar: Sendable, Hashable {
    let serviceId: String
    let weekdays: [Bool]
    let startDate: Int
    let endDate: Int

    func isActive(on serviceDay: ServiceDay) -> Bool {
        guard serviceDay.yyyymmdd >= startDate,
              serviceDay.yyyymmdd <= endDate,
              weekdays.indices.contains(serviceDay.weekdayIndex)
        else { return false }
        return weekdays[serviceDay.weekdayIndex]
    }
}

private struct ServiceException: Sendable, Hashable {
    let serviceId: String
    let date: Int
    let exceptionType: Int
}

private struct ServiceDay: Sendable, Hashable {
    let midnight: Date
    let yyyymmdd: Int
    let weekdayIndex: Int

    init(midnight: Date, calendar: Calendar) {
        self.midnight = midnight
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: midnight)
        self.yyyymmdd = (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
        // GTFS calendar weekdays are Monday...Sunday; Foundation uses
        // Sunday = 1, Monday = 2.
        self.weekdayIndex = ((components.weekday ?? 2) + 5) % 7
    }
}
