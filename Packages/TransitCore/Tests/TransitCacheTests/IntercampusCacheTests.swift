import Foundation
import SwiftData
import Testing
@testable import TransitCache
import TransitModels

@Suite("Intercampus cache")
struct IntercampusCacheTests {
    @Test func roundTripsIntercampusArrivalsThroughSnapshot() async throws {
        let container = try ModelContainer.ephemeral()
        let store = TransitStore(container: container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let arrival = IntercampusArrival(
            id: "intercampus-test",
            routeId: "23174203-507c-48fe-811a-5d13fcf7be65",
            direction: .northbound,
            tripId: "trip",
            vehicleId: "35002",
            vehicleLabel: "35002",
            stopId: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
            stopName: "Ward",
            destinationName: "Evanston",
            generatedAt: now,
            arrivalAt: now.addingTimeInterval(300),
            delaySeconds: nil,
            isDelayed: false,
            timeSource: .schedule
        )

        await store.replaceIntercampusArrivals([arrival])
        let snapshot = await store.currentSnapshot(now: now)

        #expect(snapshot.intercampusArrivals == [arrival])
        #expect(snapshot.intercampusArrivals.first?.timeSource == .schedule)
        #expect(snapshot.intercampusFetchedAt != nil)
    }
}
