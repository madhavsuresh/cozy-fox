import Foundation

public enum AmtrakStationCatalog {
    public static var all: [AmtrakStation] { AmtrakCatalogStore.shared.stations }
    public static var routes: [AmtrakRoute] { AmtrakCatalogStore.shared.routes }
    public static var allRouteIds: [String] { AmtrakCatalogStore.shared.allRouteIds }
    public static var feedInfo: AmtrakFeedInfo { AmtrakCatalogStore.shared.feedInfo }

    public static func route(id: String) -> AmtrakRoute? {
        AmtrakCatalogStore.shared.routeById[id]
    }

    public static func station(id: String) -> AmtrakStation? {
        AmtrakCatalogStore.shared.stationById[id]
    }

    public static func stations(onRoute routeId: String) -> [AmtrakStation] {
        AmtrakCatalogStore.shared.stationsByRoute[routeId] ?? []
    }

    public static func directionChoices(
        routeId: String,
        stationId: String,
        now: Date = .now
    ) -> [AmtrakDirectionChoice] {
        departureGroups(routeId: routeId, stationId: stationId, now: now, limitPerGroup: 1)
            .map { group in
                AmtrakDirectionChoice(
                    routeId: group.routeId,
                    directionId: group.directionId,
                    destinationName: group.title,
                    nextDepartureAt: group.nextDepartureAt
                )
            }
    }

    public static func directionId(
        routeId: String,
        boardingStationId: String,
        targetStationId: String
    ) -> Int? {
        AmtrakCatalogStore.shared.directionId(
            routeId: routeId,
            boardingStationId: boardingStationId,
            targetStationId: targetStationId
        )
    }

    public static func departureGroups(
        routeId: String,
        stationId: String,
        now: Date = .now,
        horizon: TimeInterval = 24 * 60 * 60,
        limitPerGroup: Int = 3
    ) -> [AmtrakDepartureGroup] {
        AmtrakCatalogStore.shared.departureGroups(
            routeId: routeId,
            stationId: stationId,
            now: now,
            horizon: horizon,
            limitPerGroup: limitPerGroup
        )
    }
}

public enum AmtrakScheduleCatalog {
    public static func upcomingDepartures(
        stationId: String? = nil,
        routeId: String? = nil,
        directionId: Int? = nil,
        destinationName: String? = nil,
        now: Date = .now,
        horizon: TimeInterval = 6 * 60 * 60,
        limit: Int = 8
    ) -> [AmtrakPrediction] {
        AmtrakCatalogStore.shared.upcomingDepartures(
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

public struct AmtrakFeedInfo: Codable, Sendable, Hashable {
    public let publisherName: String
    public let publisherURL: URL?
    public let version: String?
    public let startDate: String?
    public let endDate: String?

    public init(
        publisherName: String,
        publisherURL: URL?,
        version: String?,
        startDate: String?,
        endDate: String?
    ) {
        self.publisherName = publisherName
        self.publisherURL = publisherURL
        self.version = version
        self.startDate = startDate
        self.endDate = endDate
    }
}

struct AmtrakCatalogStore: Sendable {
    static let shared = AmtrakCatalogStore()

    let routes: [AmtrakRoute]
    let allRouteIds: [String]
    let stations: [AmtrakStation]
    let services: [AmtrakService]
    let exceptions: [AmtrakServiceException]
    let schedule: [AmtrakScheduleEntry]
    let feedInfo: AmtrakFeedInfo
    let routeById: [String: AmtrakRoute]
    let stationById: [String: AmtrakStation]
    let stationsByRoute: [String: [AmtrakStation]]
    let scheduleByStationRoute: [String: [AmtrakScheduleEntry]]
    let scheduleByTripId: [String: [AmtrakScheduleEntry]]

    init() {
        let resource = Self.loadResource()
        self.init(
            routes: resource.routes.map(\.model),
            stations: resource.stations.map(\.model),
            services: resource.services.map(\.model),
            exceptions: resource.exceptions.map(\.model),
            schedule: resource.schedule.map(\.model),
            feedInfo: resource.feedInfo?.model ?? AmtrakFeedInfo(
                publisherName: "Amtrak",
                publisherURL: URL(string: "https://www.amtrak.com"),
                version: nil,
                startDate: nil,
                endDate: nil
            )
        )
    }

    init(
        routes: [AmtrakRoute],
        stations: [AmtrakStation],
        services: [AmtrakService],
        exceptions: [AmtrakServiceException],
        schedule: [AmtrakScheduleEntry],
        feedInfo: AmtrakFeedInfo
    ) {
        self.routes = routes
        self.allRouteIds = routes.map(\.id)
        self.stations = stations
        self.services = services
        self.exceptions = exceptions
        self.schedule = schedule
        self.feedInfo = feedInfo
        self.routeById = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
        self.stationById = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })

        var stationBuckets: [String: [AmtrakStation]] = [:]
        for station in stations {
            for route in station.servedRoutes {
                stationBuckets[route, default: []].append(station)
            }
        }
        self.stationsByRoute = stationBuckets.mapValues { $0.sorted { $0.name < $1.name } }

        var scheduleBuckets: [String: [AmtrakScheduleEntry]] = [:]
        for entry in schedule {
            scheduleBuckets[Self.scheduleKey(stationId: entry.stopId, routeId: entry.routeId), default: []].append(entry)
        }
        self.scheduleByStationRoute = scheduleBuckets
        self.scheduleByTripId = Dictionary(grouping: schedule, by: \.tripId)
            .mapValues { entries in entries.sorted { $0.stopSequence < $1.stopSequence } }
    }

    func scheduleEntries(stationId: String, routeId: String) -> [AmtrakScheduleEntry] {
        scheduleByStationRoute[Self.scheduleKey(stationId: stationId, routeId: routeId)] ?? []
    }

    func directionId(
        routeId: String,
        boardingStationId: String,
        targetStationId: String
    ) -> Int? {
        guard boardingStationId != targetStationId else { return nil }

        var counts: [Int: Int] = [:]
        for entries in scheduleByTripId.values {
            let routeEntries = entries.filter { $0.routeId == routeId }
            guard let boarding = routeEntries.first(where: { $0.stopId == boardingStationId }),
                  let target = routeEntries.first(where: { $0.stopId == targetStationId }),
                  target.stopSequence > boarding.stopSequence,
                  let directionId = boarding.directionId ?? target.directionId
            else { continue }
            counts[directionId, default: 0] += 1
        }

        return counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.first?.key
    }

    func departureGroups(
        routeId: String,
        stationId: String,
        now: Date,
        horizon: TimeInterval,
        limitPerGroup: Int
    ) -> [AmtrakDepartureGroup] {
        let entries = scheduleEntries(stationId: stationId, routeId: routeId)
        let directionIds = Set(entries.compactMap(\.directionId)).sorted()
        let limit = max(limitPerGroup * 4, limitPerGroup)
        let predictions: [AmtrakPrediction]
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
        return AmtrakDepartureGrouper.groups(from: unique, limitPerGroup: limitPerGroup)
    }

    func upcomingDepartures(
        stationId: String?,
        routeId: String?,
        directionId: Int?,
        destinationName: String?,
        now: Date,
        horizon: TimeInterval,
        limit: Int
    ) -> [AmtrakPrediction] {
        let entries: [AmtrakScheduleEntry] = {
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

        let stationTimeZone = stationId
            .flatMap { stationById[$0]?.timeZoneIdentifier }
            .flatMap(TimeZone.init(identifier:))

        let candidates = serviceDates(around: now, timeZone: stationTimeZone).flatMap { serviceDate -> [AmtrakPrediction] in
            let active = activeServiceIds(on: serviceDate.date, timeZone: serviceDate.timeZone)
            guard !active.isEmpty else { return [] }
            return filtered.compactMap { entry in
                guard active.contains(entry.serviceId) else { return nil }
                let departure = serviceDate.startOfDay.addingTimeInterval(TimeInterval(entry.departureSeconds))
                guard departure >= now.addingTimeInterval(-120),
                      departure <= now.addingTimeInterval(horizon)
                else { return nil }
                guard let station = stationById[entry.stopId] else { return nil }
                let route = routeById[entry.routeId]
                return AmtrakPrediction(
                    id: "amtrak-\(entry.tripId)-\(entry.stopId)-\(Int(departure.timeIntervalSince1970))",
                    routeId: entry.routeId,
                    routeName: route?.displayName ?? entry.routeId,
                    routeKind: route?.kind ?? .other,
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
                    isScheduled: true,
                    sourceLabel: "Schedule"
                )
            }
        }

        return Array(candidates.sorted { $0.arrivalAt < $1.arrivalAt }.prefix(limit))
    }

    private func serviceDates(
        around date: Date,
        timeZone: TimeZone?
    ) -> [(date: Date, startOfDay: Date, timeZone: TimeZone)] {
        let tz = timeZone ?? Self.defaultTimeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return (-1...1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else {
                return nil
            }
            let start = calendar.startOfDay(for: day)
            return (start, start, tz)
        }
    }

    private func activeServiceIds(on date: Date, timeZone: TimeZone) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let key = Self.serviceDateString(from: date, timeZone: timeZone)
        let appleWeekday = calendar.component(.weekday, from: date)
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

    private static let defaultTimeZone = TimeZone(identifier: "America/Chicago") ?? .current

    private static func serviceDateString(from date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func loadResource() -> AmtrakCatalogResource {
        guard let url = Bundle.module.url(forResource: "AmtrakCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AmtrakCatalogResource.self, from: data)
        else {
            return AmtrakCatalogResource(
                source: nil,
                generatedFrom: nil,
                agency: nil,
                feedInfo: nil,
                routes: [],
                stations: [],
                services: [],
                exceptions: [],
                schedule: []
            )
        }
        return decoded
    }
}

struct AmtrakScheduleEntry: Sendable, Hashable {
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

struct AmtrakService: Sendable, Hashable {
    let id: String
    let weekdays: [Bool]
    let startDate: String
    let endDate: String
}

struct AmtrakServiceException: Sendable, Hashable {
    let serviceId: String
    let date: String
    let type: Int
}

private struct AmtrakCatalogResource: Decodable {
    let source: String?
    let generatedFrom: String?
    let agency: [String: String]?
    let feedInfo: FeedInfoRow?
    let routes: [RouteRow]
    let stations: [StationRow]
    let services: [ServiceRow]
    let exceptions: [ExceptionRow]
    let schedule: [ScheduleRow]

    struct FeedInfoRow: Decodable {
        let model: AmtrakFeedInfo

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let row = try c.decode([String: String].self)
            model = AmtrakFeedInfo(
                publisherName: row["feed_publisher_name"] ?? "Amtrak",
                publisherURL: row["feed_publisher_url"].flatMap(URL.init(string:)),
                version: row["feed_version"],
                startDate: row["feed_start_date"],
                endDate: row["feed_end_date"]
            )
        }
    }

    struct RouteRow: Decodable {
        let model: AmtrakRoute

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            let shortName = try c.decode(String.self)
            let longName = try c.decode(String.self)
            let kind = try c.decode(Int.self)
            let urlString = try c.decode(String.self)
            let colorHex = try c.decode(String.self)
            let textColorHex = try c.decode(String.self)
            model = AmtrakRoute(
                id: id,
                shortName: shortName,
                longName: longName,
                kind: AmtrakRouteKind(rawValue: kind) ?? .other,
                url: URL(string: urlString),
                colorHex: colorHex,
                textColorHex: textColorHex
            )
        }
    }

    struct StationRow: Decodable {
        let model: AmtrakStation

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let id = try c.decode(String.self)
            let name = try c.decode(String.self)
            let urlString = try c.decode(String.self)
            let timeZoneIdentifier = try c.decodeIfPresent(String.self)
            let latitude = try c.decode(Double.self)
            let longitude = try c.decode(Double.self)
            let servedRoutes = try c.decode([String].self)
            model = AmtrakStation(
                id: id,
                name: name,
                url: URL(string: urlString),
                timeZoneIdentifier: timeZoneIdentifier,
                latitude: latitude,
                longitude: longitude,
                servedRoutes: servedRoutes
            )
        }
    }

    struct ServiceRow: Decodable {
        let model: AmtrakService

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = AmtrakService(
                id: try c.decode(String.self),
                weekdays: try c.decode([Bool].self),
                startDate: try c.decode(String.self),
                endDate: try c.decode(String.self)
            )
        }
    }

    struct ExceptionRow: Decodable {
        let model: AmtrakServiceException

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = AmtrakServiceException(
                serviceId: try c.decode(String.self),
                date: try c.decode(String.self),
                type: try c.decode(Int.self)
            )
        }
    }

    struct ScheduleRow: Decodable {
        let model: AmtrakScheduleEntry

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            model = AmtrakScheduleEntry(
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
