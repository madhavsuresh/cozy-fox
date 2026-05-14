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
        isDelayed: Bool
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

    public static func destinationName(for direction: IntercampusDirection) -> String {
        route(for: direction)?.destinationName ?? direction.label
    }

    public static func stop(id: String) -> IntercampusStop? {
        IntercampusCatalogStore.shared.stopById[id]
    }

    public static func stops(for direction: IntercampusDirection) -> [IntercampusStop] {
        IntercampusCatalogStore.shared.stopsByDirection[direction] ?? []
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
}

private struct IntercampusCatalogResource: Decodable {
    let source: String?
    let routes: [RouteRow]
    let stops: [StopRow]
    let routeStops: [RouteStopRow]

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

    struct RouteStop: Sendable, Hashable {
        let routeId: String
        let stopId: String
        let sequence: Int
    }
}
