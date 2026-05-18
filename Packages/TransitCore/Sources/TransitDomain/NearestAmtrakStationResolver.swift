import Foundation
import TransitModels

public struct NearestAmtrakStationResolver: Sendable {
    public let maxDistanceMeters: Double

    public init(maxDistanceMeters: Double = 30_000) {
        self.maxDistanceMeters = maxDistanceMeters
    }

    public func nearest(
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [AmtrakStation] = AmtrakStationCatalog.all
    ) -> [AmtrakStation] {
        boundedNearest(in: catalog, to: point, limit: limit, matches: { _ in true })
            .map(\.station)
    }

    public func closestStations(
        onRoute routeId: String,
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [AmtrakStation] = AmtrakStationCatalog.all
    ) -> [(station: AmtrakStation, distance: Double)] {
        boundedNearest(
            in: catalog,
            to: point,
            limit: limit,
            matches: { $0.servedRoutes.contains(routeId) }
        )
    }

    public func nearestPerRoute(
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [AmtrakStation] = AmtrakStationCatalog.all
    ) -> [(routeId: String, station: AmtrakStation, distance: Double)] {
        var byRoute: [String: (station: AmtrakStation, distance: Double)] = [:]
        for station in catalog {
            let distance = Distance.meters(
                from: point,
                to: (station.latitude, station.longitude)
            )
            guard distance <= maxDistanceMeters else { continue }
            for route in station.servedRoutes {
                let current = byRoute[route]
                if current == nil || distance < current!.distance {
                    byRoute[route] = (station, distance)
                }
            }
        }
        return Array(byRoute.map { (routeId: $0.key, station: $0.value.station, distance: $0.value.distance) }
            .sorted { $0.distance < $1.distance }
            .prefix(limit))
    }

    private func boundedNearest(
        in catalog: [AmtrakStation],
        to point: (lat: Double, lon: Double),
        limit: Int,
        matches: (AmtrakStation) -> Bool
    ) -> [(station: AmtrakStation, distance: Double)] {
        guard limit > 0 else { return [] }
        var best: [(station: AmtrakStation, distance: Double)] = []
        best.reserveCapacity(limit)
        for station in catalog where matches(station) {
            let distance = Distance.meters(
                from: point,
                to: (station.latitude, station.longitude)
            )
            guard distance <= maxDistanceMeters else { continue }
            insert((station: station, distance: distance), into: &best, limit: limit)
        }
        return best
    }

    private func insert(
        _ entry: (station: AmtrakStation, distance: Double),
        into best: inout [(station: AmtrakStation, distance: Double)],
        limit: Int
    ) {
        let index = best.firstIndex { entry.distance < $0.distance } ?? best.endIndex
        if index < best.endIndex {
            best.insert(entry, at: index)
        } else if best.count < limit {
            best.append(entry)
        }
        if best.count > limit {
            best.removeLast()
        }
    }
}
