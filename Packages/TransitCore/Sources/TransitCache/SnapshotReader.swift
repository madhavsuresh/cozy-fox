import Foundation
import SwiftData
import TransitModels

/// Reads a complete `TransitSnapshot` from SwiftData. Used by the widget
/// extension on every timeline refresh — pure read, no I/O.
///
/// Intentionally NOT `@MainActor`-isolated so the widget timeline provider can
/// call it from any context. SwiftData `ModelContext` is created fresh per
/// call and never shared across threads.
public struct SnapshotReader: Sendable {
    public let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func loadSnapshot(now: Date = .now) -> TransitSnapshot {
        let context = ModelContext(container)

        let trainArrivals = (try? context.fetch(FetchDescriptor<CachedTrainArrival>())) ?? []
        let busPredictions = (try? context.fetch(FetchDescriptor<CachedBusPrediction>())) ?? []
        let metraPredictions = (try? context.fetch(FetchDescriptor<CachedMetraPrediction>())) ?? []
        let vehiclePositions = (try? context.fetch(FetchDescriptor<CachedVehiclePosition>())) ?? []
        let intercampusArrivals = (try? context.fetch(FetchDescriptor<CachedIntercampusArrival>())) ?? []
        let alerts = (try? context.fetch(FetchDescriptor<CachedAlert>())) ?? []
        let nearestBikes = (try? context.fetch(FetchDescriptor<CachedNearestBike>())) ?? []
        let nearestFreeBikes = (try? context.fetch(FetchDescriptor<CachedNearestFreeBike>())) ?? []
        let tripBikeSummaries = (try? context.fetch(FetchDescriptor<CachedTripBikeSummary>())) ?? []
        let bikeStationRows = (
            try? context.fetch(FetchDescriptor<CachedEBikeStation>(
                sortBy: [SortDescriptor(\.snappedAt, order: .reverse)]
            ))
        ) ?? []

        let arrivals = trainArrivals.compactMap(\.asModel)
            .filter { $0.arrivalAt > now.addingTimeInterval(-120) }
            .sorted { $0.arrivalAt < $1.arrivalAt }

        let predictions = busPredictions.map(\.asModel)
            .filter { $0.arrivalAt > now.addingTimeInterval(-120) }
            .sorted { $0.arrivalAt < $1.arrivalAt }

        let metra = metraPredictions.map(\.asModel)
            .filter { $0.arrivalAt > now.addingTimeInterval(-120) }
            .sorted { $0.arrivalAt < $1.arrivalAt }

        let positions = vehiclePositions.compactMap(\.asModel)
            .filter { $0.observedAt > now.addingTimeInterval(-10 * 60) }
            .sorted { $0.observedAt > $1.observedAt }

        let intercampus = intercampusArrivals.compactMap(\.asModel)
            .filter { $0.arrivalAt > now.addingTimeInterval(-120) }
            .sorted { $0.arrivalAt < $1.arrivalAt }

        let activeAlerts = alerts.map(\.asModel)
            .filter { $0.isActive(at: now) }

        let nearbyPicks = nearestBikes
            .sorted { $0.rank < $1.rank }
            .map { row -> NearestBikePick in
                let dockedBikes = Self.decodeBikes(from: row.dockedBikesJSON)
                let freeFloatingBikes = Self.decodeBikes(from: row.freeFloatingBikesJSON)
                let station = BikeStation(
                    id: row.stationId,
                    name: row.stationName,
                    latitude: row.latitude,
                    longitude: row.longitude,
                    capacity: row.capacity,
                    eBikesAvailable: row.eBikesAvailable,
                    classicBikesAvailable: 0,
                    docksAvailable: max(0, row.capacity - row.eBikesAvailable),
                    isRenting: true,
                    isReturning: true,
                    lastReported: row.computedAt
                )
                return NearestBikePick(
                    station: station,
                    walkingDistanceMeters: row.walkingDistanceMeters,
                    bestRangeMeters: row.bestRangeMeters,
                    dockedBikes: dockedBikes,
                    freeFloatingNearby: row.freeFloatingNearby,
                    nearbyFreeFloatingBikes: freeFloatingBikes,
                    computedAt: row.computedAt
                )
            }

        let nearbyFreePicks = nearestFreeBikes
            .sorted { $0.rank < $1.rank }
            .map(\.asModel)

        let latestBikeStations = Self.latestStations(from: bikeStationRows)
        let tripBikeSummary = tripBikeSummaries
            .sorted { $0.computedAt > $1.computedAt }
            .first

        return TransitSnapshot(
            // 50 / 50 is enough headroom for: 3 nearest stations × ~5 trains
            // each + the pinned-line station + a couple of tracked stations,
            // and 5 nearest bus routes × 4 predictions each + tracked ones.
            // Previously capped at 8/8 which hid arrivals from secondary
            // stations once a busy primary station filled the budget.
            trainArrivals: Array(arrivals.prefix(50)),
            busPredictions: Array(predictions.prefix(50)),
            metraPredictions: Array(metra.prefix(50)),
            intercampusArrivals: Array(intercampus.prefix(80)),
            vehiclePositions: Array(positions.prefix(80)),
            nearestBike: nearbyPicks.first,
            nearbyBikePicks: nearbyPicks,
            nearbyFreeBikePicks: nearbyFreePicks,
            bikeStations: latestBikeStations,
            tripFreeFloatingBikeCount: tripBikeSummary?.freeFloatingBikeCount ?? 0,
            activeAlerts: activeAlerts,
            trainsFetchedAt: trainArrivals.first?.fetchedAt,
            busesFetchedAt: busPredictions.first?.fetchedAt,
            metraFetchedAt: metraPredictions.first?.fetchedAt,
            intercampusFetchedAt: intercampusArrivals.first?.fetchedAt,
            bikesFetchedAt: nearbyPicks.first?.computedAt
                ?? nearbyFreePicks.first?.computedAt
                ?? tripBikeSummary?.computedAt,
            alertsFetchedAt: alerts.first?.fetchedAt
        )
    }

    private static func latestStations(from rows: [CachedEBikeStation]) -> [BikeStation] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard seen.insert(row.stationId).inserted else { return nil }
            return row.asModel
        }
    }

    private static func decodeBikes(from json: String?) -> [EBike] {
        guard let json else { return [] }
        return (try? JSONDecoder().decode([EBike].self, from: Data(json.utf8))) ?? []
    }
}
