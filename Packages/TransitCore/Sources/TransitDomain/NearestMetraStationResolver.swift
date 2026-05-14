import Foundation
import TransitModels

public struct NearestMetraStationResolver: Sendable {
    public let maxDistanceMeters: Double

    public init(maxDistanceMeters: Double = 20_000) {
        self.maxDistanceMeters = maxDistanceMeters
    }

    public func nearest(
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [MetraStation] = MetraStationCatalog.all
    ) -> [MetraStation] {
        Array(catalog
            .map { station in
                (
                    station: station,
                    distance: Distance.meters(
                        from: point,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxDistanceMeters }
            .sorted { $0.distance < $1.distance }
            .map(\.station)
            .prefix(limit))
    }

    public func closestStations(
        onRoute routeId: String,
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [MetraStation] = MetraStationCatalog.all
    ) -> [(station: MetraStation, distance: Double)] {
        Array(catalog
            .filter { $0.servedRoutes.contains(routeId) }
            .map { station in
                (
                    station: station,
                    distance: Distance.meters(
                        from: point,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxDistanceMeters }
            .sorted { $0.distance < $1.distance }
            .prefix(limit))
    }

    public func nearestPerRoute(
        to point: (lat: Double, lon: Double),
        limit: Int,
        catalog: [MetraStation] = MetraStationCatalog.all
    ) -> [(routeId: String, station: MetraStation, distance: Double)] {
        var byRoute: [String: (station: MetraStation, distance: Double)] = [:]
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
}
