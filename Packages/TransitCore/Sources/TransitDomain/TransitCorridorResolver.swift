import Foundation
import TransitModels

public enum TransitCorridor: String, CaseIterable, Sendable, Hashable {
    case northSouth
    case eastWest
    case diagonal
    case loop

    public static let busOrder: [TransitCorridor] = [.northSouth, .eastWest, .diagonal]
    public static let trainOrder: [TransitCorridor] = [.northSouth, .eastWest, .diagonal, .loop]
}

public struct NearbyTrainCorridorCandidate: Sendable, Hashable, Identifiable {
    public let corridor: TransitCorridor
    public let line: LineColor
    public let station: LStation
    public let distanceMeters: Double

    public var id: String {
        "\(corridor.rawValue)-\(line.rawValue)-\(station.id)"
    }

    public init(
        corridor: TransitCorridor,
        line: LineColor,
        station: LStation,
        distanceMeters: Double
    ) {
        self.corridor = corridor
        self.line = line
        self.station = station
        self.distanceMeters = distanceMeters
    }
}

public struct NearbyBusCorridorCandidate: Sendable, Hashable, Identifiable {
    public let corridor: TransitCorridor
    public let stop: BusStop
    public let distanceMeters: Double

    public var id: String {
        "\(corridor.rawValue)-\(stop.route)-\(stop.id)"
    }

    public init(corridor: TransitCorridor, stop: BusStop, distanceMeters: Double) {
        self.corridor = corridor
        self.stop = stop
        self.distanceMeters = distanceMeters
    }
}

public struct TransitCorridorResolver: Sendable {
    public let maxLocalStops: Int
    public let localRouteRadiusMeters: Double

    public init(
        maxLocalStops: Int = 16,
        localRouteRadiusMeters: Double = 2_500
    ) {
        self.maxLocalStops = maxLocalStops
        self.localRouteRadiusMeters = localRouteRadiusMeters
    }

    public func nearbyTrainCandidates(
        to origin: (lat: Double, lon: Double),
        radiusMeters: Double = 2_000,
        limitPerCorridor: Int = 4,
        catalog: [LStation] = LStationCatalog.all,
        excludingStationIds: Set<Int> = [],
        excludingLines: Set<LineColor> = [],
        isLineVisible: (LineColor) -> Bool = { _ in true }
    ) -> [NearbyTrainCorridorCandidate] {
        let nearbyStations = catalog
            .filter { !excludingStationIds.contains($0.id) }
            .map { station in
                (
                    station: station,
                    distance: Distance.meters(
                        from: origin,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
            .filter { $0.distance <= radiusMeters }
            .sorted { $0.distance < $1.distance }

        var byCorridor: [TransitCorridor: [NearbyTrainCorridorCandidate]] = [:]
        var seen: Set<String> = []
        for entry in nearbyStations {
            for line in entry.station.servedLines where isLineVisible(line) && !excludingLines.contains(line) {
                let corridor = trainCorridor(for: line, near: entry.station, catalog: catalog)
                let candidate = NearbyTrainCorridorCandidate(
                    corridor: corridor,
                    line: line,
                    station: entry.station,
                    distanceMeters: entry.distance
                )
                guard seen.insert(candidate.id).inserted else { continue }
                byCorridor[corridor, default: []].append(candidate)
            }
        }

        return TransitCorridor.trainOrder.flatMap { corridor in
            byCorridor[corridor, default: []]
                .sorted { lhs, rhs in
                    if lhs.distanceMeters != rhs.distanceMeters {
                        return lhs.distanceMeters < rhs.distanceMeters
                    }
                    if lhs.line.rawValue != rhs.line.rawValue {
                        return lhs.line.rawValue < rhs.line.rawValue
                    }
                    return lhs.station.id < rhs.station.id
                }
                .prefix(max(0, limitPerCorridor))
        }
    }

    public func nearbyBusCandidates(
        to origin: (lat: Double, lon: Double),
        radiusMeters: Double = 1_500,
        limitPerCorridor: Int = 6,
        catalog: [BusStop] = BusStopCatalog.all,
        excludingRoute: String? = nil,
        isRouteVisible: (String) -> Bool = { _ in true }
    ) -> [NearbyBusCorridorCandidate] {
        var bestByRoute: [String: (stop: BusStop, distance: Double)] = [:]
        var stopsByRoute: [String: [BusStop]] = [:]
        for stop in catalog {
            if let excludingRoute, stop.route == excludingRoute {
                continue
            }
            guard isRouteVisible(stop.route) else { continue }
            stopsByRoute[stop.route, default: []].append(stop)
            let distance = Distance.meters(
                from: origin,
                to: (stop.latitude, stop.longitude)
            )
            guard distance <= radiusMeters else { continue }
            if bestByRoute[stop.route].map({ distance < $0.distance }) ?? true {
                bestByRoute[stop.route] = (stop, distance)
            }
        }

        var byCorridor: [TransitCorridor: [NearbyBusCorridorCandidate]] = [:]
        for entry in bestByRoute.values {
            let corridor = busCorridor(forStops: stopsByRoute[entry.stop.route, default: []], near: origin)
            guard corridor != .loop else { continue }
            byCorridor[corridor, default: []].append(NearbyBusCorridorCandidate(
                corridor: corridor,
                stop: entry.stop,
                distanceMeters: entry.distance
            ))
        }

        return TransitCorridor.busOrder.flatMap { corridor in
            byCorridor[corridor, default: []]
                .sorted { lhs, rhs in
                    if lhs.distanceMeters != rhs.distanceMeters {
                        return lhs.distanceMeters < rhs.distanceMeters
                    }
                    if lhs.stop.route.localizedStandardCompare(rhs.stop.route) != .orderedSame {
                        return lhs.stop.route.localizedStandardCompare(rhs.stop.route) == .orderedAscending
                    }
                    return lhs.stop.id < rhs.stop.id
                }
                .prefix(max(0, limitPerCorridor))
        }
    }

    public func trainCorridor(
        for line: LineColor,
        near station: LStation,
        catalog: [LStation] = LStationCatalog.all
    ) -> TransitCorridor {
        if isLoopStation(station), usesLoop(line) {
            return .loop
        }

        let lineStations = catalog.filter { $0.servedLines.contains(line) }
        let ranked = lineStations
            .map { candidate in
                (
                    station: candidate,
                    distance: Distance.meters(
                        from: (station.latitude, station.longitude),
                        to: (candidate.latitude, candidate.longitude)
                    )
                )
            }
            .sorted { $0.distance < $1.distance }

        let local = ranked
            .filter { $0.distance <= localRouteRadiusMeters }
            .map { $0.station }
        let sample = local.count >= 3
            ? local
            : ranked.prefix(maxLocalStops).map { $0.station }
        return corridor(for: sample.map { ($0.latitude, $0.longitude) })
    }

    public func busCorridor(
        forRoute route: String,
        near origin: (lat: Double, lon: Double),
        catalog: [BusStop] = BusStopCatalog.all
    ) -> TransitCorridor {
        busCorridor(forStops: catalog.filter { $0.route == route }, near: origin)
    }

    private func busCorridor(
        forStops stops: [BusStop],
        near origin: (lat: Double, lon: Double)
    ) -> TransitCorridor {
        let uniqueStops = uniqueStops(stops)
        let ranked = uniqueStops
            .map { stop in
                (
                    stop: stop,
                    distance: Distance.meters(
                        from: origin,
                        to: (stop.latitude, stop.longitude)
                    )
                )
            }
            .sorted { $0.distance < $1.distance }

        let local = ranked
            .filter { $0.distance <= localRouteRadiusMeters }
            .map { $0.stop }
        let sample = local.count >= 3
            ? local
            : ranked.prefix(maxLocalStops).map { $0.stop }
        return corridor(for: sample.map { ($0.latitude, $0.longitude) })
    }

    private func corridor(for points: [(lat: Double, lon: Double)]) -> TransitCorridor {
        guard points.count >= 2 else { return .diagonal }

        let meanLat = points.map(\.lat).reduce(0, +) / Double(points.count)
        let meanLon = points.map(\.lon).reduce(0, +) / Double(points.count)
        let latitudeScale = cos(meanLat * .pi / 180)

        var xx = 0.0
        var xy = 0.0
        var yy = 0.0
        for point in points {
            let x = (point.lon - meanLon) * latitudeScale
            let y = point.lat - meanLat
            xx += x * x
            xy += x * y
            yy += y * y
        }

        guard xx + yy > 0 else { return .diagonal }
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let degreesFromEast = abs(atan2(abs(sin(theta)), abs(cos(theta))) * 180 / .pi)

        if degreesFromEast <= 22.5 {
            return .eastWest
        }
        if degreesFromEast >= 67.5 {
            return .northSouth
        }
        return .diagonal
    }

    private func uniqueStops(_ stops: [BusStop]) -> [BusStop] {
        var seen: Set<Int> = []
        return stops.filter { seen.insert($0.id).inserted }
    }

    private func usesLoop(_ line: LineColor) -> Bool {
        switch line {
        case .brown, .orange, .pink, .purple:
            return true
        case .red, .blue, .green, .yellow:
            return false
        }
    }

    private func isLoopStation(_ station: LStation) -> Bool {
        Self.loopStationNames.contains(station.name)
    }

    private static let loopStationNames: Set<String> = [
        "Clark/Lake",
        "State/Lake",
        "Washington/Wabash",
        "Adams/Wabash",
        "Harold Washington Library-State/Van Buren",
        "LaSalle/Van Buren",
        "Quincy/Wells",
        "Washington/Wells",
        "Merchandise Mart"
    ]
}
