import Foundation
import TransitModels

public struct TripDivvyStationPick: Sendable, Hashable, Identifiable {
    public let station: BikeStation
    public let distanceMeters: Double

    public init(station: BikeStation, distanceMeters: Double) {
        self.station = station
        self.distanceMeters = distanceMeters
    }

    public var id: String { station.id }

    public var walkingMinutes: Int {
        max(1, Int((distanceMeters / 84.0).rounded()))
    }
}

public struct TripDivvyResolver: Sendable {
    public let radiusMeters: Double
    public let minimumUsableRangeMeters: Double

    public init(
        radiusMeters: Double = 400,
        minimumUsableRangeMeters: Double = 3_000
    ) {
        self.radiusMeters = radiusMeters
        self.minimumUsableRangeMeters = minimumUsableRangeMeters
    }

    public func originStations(
        near coordinate: (lat: Double, lon: Double),
        stations: [BikeStation],
        limit: Int = 2
    ) -> [TripDivvyStationPick] {
        rankedStations(
            near: coordinate,
            stations: stations,
            limit: limit,
            isEligible: { $0.isRenting && $0.eBikesAvailable > 0 },
            inventoryCount: \.eBikesAvailable
        )
    }

    public func destinationDockStations(
        near coordinate: (lat: Double, lon: Double),
        stations: [BikeStation],
        limit: Int = 2
    ) -> [TripDivvyStationPick] {
        rankedStations(
            near: coordinate,
            stations: stations,
            limit: limit,
            isEligible: { $0.isReturning && $0.docksAvailable > 0 },
            inventoryCount: \.docksAvailable
        )
    }

    public func freeFloatingEBikeCount(
        near coordinate: (lat: Double, lon: Double),
        eBikes: [EBike],
        includeFreeFloating: Bool
    ) -> Int {
        guard includeFreeFloating else { return 0 }

        return eBikes
            .filter { bike in
                bike.isFreeFloating
                    && !bike.isReserved
                    && !bike.isDisabled
                    && bike.currentRangeMeters >= minimumUsableRangeMeters
            }
            .filter { bike in
                Distance.meters(
                    from: coordinate,
                    to: (bike.latitude, bike.longitude)
                ) <= radiusMeters
            }
            .count
    }

    private func rankedStations(
        near coordinate: (lat: Double, lon: Double),
        stations: [BikeStation],
        limit: Int,
        isEligible: (BikeStation) -> Bool,
        inventoryCount: KeyPath<BikeStation, Int>
    ) -> [TripDivvyStationPick] {
        guard limit > 0 else { return [] }

        return stations
            .compactMap { station -> StationCandidate? in
                guard isEligible(station) else { return nil }
                let distance = Distance.meters(
                    from: coordinate,
                    to: (station.latitude, station.longitude)
                )
                guard distance <= radiusMeters else { return nil }
                return StationCandidate(
                    station: station,
                    distanceMeters: distance,
                    inventoryCount: station[keyPath: inventoryCount]
                )
            }
            .sorted()
            .prefix(limit)
            .map {
                TripDivvyStationPick(
                    station: $0.station,
                    distanceMeters: $0.distanceMeters
                )
            }
    }
}

private struct StationCandidate: Comparable {
    let station: BikeStation
    let distanceMeters: Double
    let inventoryCount: Int

    static func < (lhs: StationCandidate, rhs: StationCandidate) -> Bool {
        if lhs.distanceMeters != rhs.distanceMeters {
            return lhs.distanceMeters < rhs.distanceMeters
        }
        if lhs.inventoryCount != rhs.inventoryCount {
            return lhs.inventoryCount > rhs.inventoryCount
        }
        return lhs.station.id < rhs.station.id
    }
}
