import Foundation

public enum MetraStationCatalog {
    public static var all: [MetraStation] { MetraCatalogStore.shared.stations }
    public static var routes: [MetraLine] { MetraCatalogStore.shared.routes }
    public static var allRouteIds: [String] { MetraCatalogStore.shared.allRouteIds }

    public static func route(id: String) -> MetraLine? {
        MetraCatalogStore.shared.routeById[id]
    }

    public static func station(id: String) -> MetraStation? {
        MetraCatalogStore.shared.stationById[id]
    }

    public static func stations(onRoute routeId: String) -> [MetraStation] {
        MetraCatalogStore.shared.stationsByRoute[routeId] ?? []
    }

    public static func directionChoices(
        routeId: String,
        stationId: String,
        now: Date = .now
    ) -> [MetraDirectionChoice] {
        departureGroups(routeId: routeId, stationId: stationId, now: now, limitPerGroup: 1)
            .map { group in
                MetraDirectionChoice(
                    routeId: group.routeId,
                    directionId: group.directionId,
                    destinationName: group.title,
                    nextDepartureAt: group.nextDepartureAt
                )
            }
    }

    public static func departureGroups(
        routeId: String,
        stationId: String,
        now: Date = .now,
        horizon: TimeInterval = 24 * 60 * 60,
        limitPerGroup: Int = 3
    ) -> [MetraDepartureGroup] {
        MetraCatalogStore.shared.departureGroups(
            routeId: routeId,
            stationId: stationId,
            now: now,
            horizon: horizon,
            limitPerGroup: limitPerGroup
        )
    }
}

public enum MetraScheduleCatalog {
    public static func upcomingDepartures(
        stationId: String? = nil,
        routeId: String? = nil,
        directionId: Int? = nil,
        destinationName: String? = nil,
        now: Date = .now,
        horizon: TimeInterval = 6 * 60 * 60,
        limit: Int = 8
    ) -> [MetraPrediction] {
        MetraCatalogStore.shared.upcomingDepartures(
            stationId: stationId,
            routeId: routeId,
            directionId: directionId,
            destinationName: destinationName,
            now: now,
            horizon: horizon,
            limit: limit
        )
    }
}

private struct MetraCatalogStore: Sendable {
    static let shared = MetraCatalogStore()

    let routes: [MetraLine]
    let allRouteIds: [String]
    let stations: [MetraStation]
    let services: [MetraService]
    let exceptions: [MetraServiceException]
    let schedule: [MetraScheduleEntry]
    let routeById: [String: MetraLine]
    let stationById: [String: MetraStation]
    let stationsByRoute: [String: [MetraStation]]
    let scheduleByStationRoute: [String: [MetraScheduleEntry]]
    let lastStopSequenceByTrip: [String: Int]

    init() {
        let resource = Self.loadResource()
        self.routes = resource.routes.map(\.model)
        self.allRouteIds = self.routes.map(\.id)
        self.stations = resource.stations.map(\.model)
        self.services = resource.services.map(\.model)
        self.exceptions = resource.exceptions.map(\.model)
        self.schedule = resource.schedule.map(\.model)
        self.routeById = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        self.stationById = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })

        var lastStops: [String: Int] = [:]
        for entry in schedule {
            lastStops[entry.tripId] = max(lastStops[entry.tripId] ?? entry.stopSequence, entry.stopSequence)
        }
        self.lastStopSequenceByTrip = lastStops

        var stationBuckets: [String: [MetraStation]] = [:]
        for station in stations {
            for route in station.servedRoutes {
                stationBuckets[route, default: []].append(station)
            }
        }
        self.stationsByRoute = stationBuckets.mapValues { $0.sorted { $0.name < $1.name } }

        var scheduleBuckets: [String: [MetraScheduleEntry]] = [:]
        for entry in schedule {
            scheduleBuckets[Self.scheduleKey(stationId: entry.stopId, routeId: entry.routeId), default: []].append(entry)
        }
        self.scheduleByStationRoute = scheduleBuckets
    }

    func scheduleEntries(stationId: String, routeId: String) -> [MetraScheduleEntry] {
        scheduleByStationRoute[Self.scheduleKey(stationId: stationId, routeId: routeId)] ?? []
    }

    func departureGroups(
        routeId: String,
        stationId: String,
        now: Date,
        horizon: TimeInterval,
        limitPerGroup: Int
    ) -> [MetraDepartureGroup] {
        let entries = scheduleEntries(stationId: stationId, routeId: routeId)
        let directionIds = Set(entries.compactMap(\.directionId)).sorted()
        let limit = max(limitPerGroup * 4, limitPerGroup)
        let predictions: [MetraPrediction]
        if directionIds.isEmpty {
            predictions = upcomingDepartures(
                stationId: stationId,
                routeId: routeId,
                directionId: nil,
                destinationName: nil,
                now: now,
                horizon: horizon,
                limit: limit * 2
            )
        } else {
            predictions = directionIds.flatMap { directionId in
                upcomingDepartures(
                    stationId: stationId,
                    routeId: routeId,
                    directionId: directionId,
                    destinationName: nil,
                    now: now,
                    horizon: horizon,
                    limit: limit
                )
            }
        }

        var seen: Set<String> = []
        let unique = predictions
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .filter { seen.insert($0.id).inserted }
        return MetraDepartureGrouper.groups(from: unique, limitPerGroup: limitPerGroup)
    }

    func upcomingDepartures(
        stationId: String?,
        routeId: String?,
        directionId: Int?,
        destinationName: String?,
        now: Date,
        horizon: TimeInterval,
        limit: Int
    ) -> [MetraPrediction] {
        let entries: [MetraScheduleEntry] = {
            if let stationId, let routeId {
                return scheduleEntries(stationId: stationId, routeId: routeId)
            }
            return schedule
        }()
        let filtered = entries.filter { entry in
            if let stationId, entry.stopId != stationId { return false }
            if let routeId, entry.routeId != routeId { return false }
            if let directionId, entry.directionId != directionId { return false }
            if let destinationName, entry.headsign != destinationName { return false }
            return true
        }

        let candidates = serviceDates(around: now).flatMap { serviceDate -> [MetraPrediction] in
            let active = activeServiceIds(on: serviceDate.date)
            guard !active.isEmpty else { return [] }
            return filtered.compactMap { entry in
                guard active.contains(entry.serviceId) else { return nil }
                if let lastStopSequence = lastStopSequenceByTrip[entry.tripId],
                   entry.stopSequence >= lastStopSequence {
                    return nil
                }
                let departure = serviceDate.startOfDay.addingTimeInterval(TimeInterval(entry.departureSeconds))
                guard departure >= now.addingTimeInterval(-120),
                      departure <= now.addingTimeInterval(horizon)
                else { return nil }
                guard let station = stationById[entry.stopId] else { return nil }
                let route = routeById[entry.routeId]
                return MetraPrediction(
                    id: "metra-\(entry.tripId)-\(entry.stopId)-\(Int(departure.timeIntervalSince1970))",
                    routeId: entry.routeId,
                    routeShortName: route?.shortName ?? entry.routeId,
                    tripId: entry.tripId,
                    trainNumber: entry.trainNumber,
                    stationId: entry.stopId,
                    stationName: station.name,
                    destinationName: entry.headsign,
                    directionId: entry.directionId,
                    generatedAt: now,
                    scheduledAt: departure,
                    arrivalAt: departure,
                    delaySeconds: nil,
                    isDelayed: false,
                    isCanceled: false,
                    isScheduled: true
                )
            }
        }

        return Array(candidates.sorted { $0.arrivalAt < $1.arrivalAt }.prefix(limit))
    }

    private func serviceDates(around date: Date) -> [(date: Date, startOfDay: Date)] {
        (-1...1).compactMap { offset in
            guard let day = Self.calendar.date(byAdding: .day, value: offset, to: date) else {
                return nil
            }
            let start = Self.calendar.startOfDay(for: day)
            return (start, start)
        }
    }

    private func activeServiceIds(on date: Date) -> Set<String> {
        let key = Self.serviceDateFormatter.string(from: date)
        // The catalog stores each service's weekday flags in GTFS
        // calendar.txt order: [Mon, Tue, Wed, Thu, Fri, Sat, Sun].
        // `Calendar.component(.weekday, ...)` returns Apple's ordering
        // (Sun=1, Mon=2, …, Sat=7), so we map it onto the GTFS slot.
        // Without this conversion a standard Mon–Fri service decodes
        // as Sun–Thu, which silently swaps weekday and weekend
        // schedules for Friday and Sunday.
        let appleWeekday = Self.calendar.component(.weekday, from: date)
        let weekdayIndex = (appleWeekday + 5) % 7
        var active = Set(services.compactMap { service -> String? in
            guard service.startDate <= key, key <= service.endDate else { return nil }
            guard service.weekdays.indices.contains(weekdayIndex),
                  service.weekdays[weekdayIndex]
            else { return nil }
            return service.id
        })

        for exception in exceptions where exception.date == key {
            if exception.type == 1 {
                active.insert(exception.serviceId)
            } else if exception.type == 2 {
                active.remove(exception.serviceId)
            }
        }
        return active
    }

    private static func scheduleKey(stationId: String, routeId: String) -> String {
        "\(stationId)|\(routeId)"
    }

    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return cal
    }()

    private static let serviceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func loadResource() -> MetraCatalogResource {
        guard let url = Bundle.module.url(forResource: "MetraCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MetraCatalogResource.self, from: data)
        else {
            return MetraCatalogResource(source: nil, routes: [], stations: [], services: [], exceptions: [], schedule: [])
        }
        return decoded
    }
}

private struct MetraScheduleEntry: Sendable, Hashable {
    let routeId: String
    let serviceId: String
    let tripId: String
    let trainNumber: String
    let headsign: String
    let directionId: Int?
    let stopId: String
    let arrivalSeconds: Int
    let departureSeconds: Int
    let stopSequence: Int
}

private struct MetraService: Sendable, Hashable {
    let id: String
    let weekdays: [Bool]
    let startDate: String
    let endDate: String
}

private struct MetraServiceException: Sendable, Hashable {
    let serviceId: String
    let date: String
    let type: Int
}

private struct MetraCatalogResource: Decodable {
    let source: String?
    let routes: [RouteRow]
    let stations: [StationRow]
    let services: [ServiceRow]
    let exceptions: [ExceptionRow]
    let schedule: [ScheduleRow]

    struct RouteRow: Decodable {
        let model: MetraLine

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            let shortName = try c.decode(String.self)
            let longName = try c.decode(String.self)
            let colorHex = try c.decode(String.self)
            let textColorHex = try c.decode(String.self)
            let urlString = try c.decode(String.self)
            model = MetraLine(
                id: id,
                shortName: shortName,
                longName: longName,
                colorHex: colorHex,
                textColorHex: textColorHex,
                url: URL(string: urlString)
            )
        }
    }

    struct StationRow: Decodable {
        let model: MetraStation

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            let name = try c.decode(String.self)
            let latitude = try c.decode(Double.self)
            let longitude = try c.decode(Double.self)
            let zoneId = try c.decodeIfPresent(String.self)
            let urlString = try c.decodeIfPresent(String.self)
            let servedRoutes = try c.decode([String].self)
            model = MetraStation(
                id: id,
                name: name,
                latitude: latitude,
                longitude: longitude,
                zoneId: zoneId,
                url: urlString.flatMap(URL.init(string:)),
                servedRoutes: servedRoutes
            )
        }
    }

    struct ServiceRow: Decodable {
        let model: MetraService

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = MetraService(
                id: try c.decode(String.self),
                weekdays: try c.decode([Bool].self),
                startDate: try c.decode(String.self),
                endDate: try c.decode(String.self)
            )
        }
    }

    struct ExceptionRow: Decodable {
        let model: MetraServiceException

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = MetraServiceException(
                serviceId: try c.decode(String.self),
                date: try c.decode(String.self),
                type: try c.decode(Int.self)
            )
        }
    }

    struct ScheduleRow: Decodable {
        let model: MetraScheduleEntry

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = MetraScheduleEntry(
                routeId: try c.decode(String.self),
                serviceId: try c.decode(String.self),
                tripId: try c.decode(String.self),
                trainNumber: try c.decode(String.self),
                headsign: try c.decode(String.self),
                directionId: try c.decodeIfPresent(Int.self),
                stopId: try c.decode(String.self),
                arrivalSeconds: try c.decode(Int.self),
                departureSeconds: try c.decode(Int.self),
                stopSequence: try c.decode(Int.self)
            )
        }
    }
}
