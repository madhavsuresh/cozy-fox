import Foundation
import TransitModels

public struct NearestIntercampusStopResolver: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let direction: IntercampusDirection
        public let stop: IntercampusStop
        public let distance: Double

        public var id: String { "\(direction.rawValue)-\(stop.id)" }

        public init(direction: IntercampusDirection, stop: IntercampusStop, distance: Double) {
            self.direction = direction
            self.stop = stop
            self.distance = distance
        }
    }

    public let maxDistanceMeters: Double

    public init(maxDistanceMeters: Double = 2_000) {
        self.maxDistanceMeters = maxDistanceMeters
    }

    public func closestStops(
        direction: IntercampusDirection,
        to origin: (lat: Double, lon: Double),
        limit: Int,
        catalog: [IntercampusStop]? = nil
    ) -> [Entry] {
        let stops = catalog ?? IntercampusCatalog.stops(for: direction)
        return stops
            .filter { $0.servedDirections.contains(direction) }
            .map { stop in
                Entry(
                    direction: direction,
                    stop: stop,
                    distance: Distance.meters(
                        from: origin,
                        to: (stop.latitude, stop.longitude)
                    )
                )
            }
            .filter { $0.distance <= maxDistanceMeters }
            .sorted { lhs, rhs in
                if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
                return lhs.stop.name < rhs.stop.name
            }
            .prefix(limit)
            .map { $0 }
    }

    public func nearestPerDirection(
        to origin: (lat: Double, lon: Double),
        limitPerDirection: Int,
        catalog: [IntercampusStop] = IntercampusCatalog.all
    ) -> [Entry] {
        IntercampusDirection.allCases.flatMap { direction in
            closestStops(
                direction: direction,
                to: origin,
                limit: limitPerDirection,
                catalog: catalog
            )
        }
    }
}
