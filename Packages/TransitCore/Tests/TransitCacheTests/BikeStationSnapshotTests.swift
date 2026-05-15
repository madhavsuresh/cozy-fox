import Foundation
import SwiftData
import Testing
@testable import TransitCache
import TransitModels

@Suite("Bike station snapshots")
struct BikeStationSnapshotTests {
    private func station(
        id: String,
        name: String? = nil,
        ebikes: Int,
        docks: Int
    ) -> BikeStation {
        BikeStation(
            id: id,
            name: name ?? id,
            latitude: 41.88,
            longitude: -87.63,
            capacity: ebikes + docks,
            eBikesAvailable: ebikes,
            classicBikesAvailable: 0,
            docksAvailable: docks,
            isRenting: true,
            isReturning: true,
            lastReported: .now
        )
    }

    @Test func snapshotUsesLatestStationRowAndTripBikeSummary() throws {
        let container = try ModelContainer.ephemeral()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        context.insert(CachedEBikeStation(
            station: station(id: "a", name: "Old A", ebikes: 1, docks: 2),
            snappedAt: now.addingTimeInterval(-60)
        ))
        context.insert(CachedEBikeStation(
            station: station(id: "a", name: "New A", ebikes: 4, docks: 7),
            snappedAt: now
        ))
        context.insert(CachedEBikeStation(
            station: station(id: "b", ebikes: 2, docks: 3),
            snappedAt: now.addingTimeInterval(-30)
        ))
        context.insert(CachedTripBikeSummary(
            freeFloatingBikeCount: 6,
            computedAt: now
        ))
        try context.save()

        let snapshot = SnapshotReader(container: container).loadSnapshot(now: now)
        let stationA = try #require(snapshot.bikeStations.first { $0.id == "a" })

        #expect(snapshot.bikeStations.count == 2)
        #expect(stationA.name == "New A")
        #expect(stationA.eBikesAvailable == 4)
        #expect(stationA.docksAvailable == 7)
        #expect(snapshot.tripFreeFloatingBikeCount == 6)
        #expect(snapshot.bikesFetchedAt == now)
    }
}
