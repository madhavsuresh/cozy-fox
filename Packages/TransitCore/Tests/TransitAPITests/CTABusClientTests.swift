import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("CTA Bus Tracker decoder")
struct CTABusClientTests {
    @Test func decodesPredictionsAndDelayFlag() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getpredictions",
            data: Fixture.load("cta_bus_predictions")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let predictions = try await client.fetchPredictions(route: "22", stopId: 1234)

        #expect(predictions.count == 2)
        let first = try #require(predictions.first)
        #expect(first.route == "22")
        #expect(first.stopId == 1234)
        #expect(first.directionName == "Northbound")
        #expect(first.destinationName == "Howard")
        #expect(!first.isApproaching, "prdctdn 3 is more than 1 min away")
        #expect(!first.isDelayed)
    }

    @Test func decodesDetoursAndActiveFlag() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getdetours",
            data: Fixture.load("cta_bus_detours")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let detours = try await client.fetchDetours(routes: ["65", "22"])

        #expect(detours.count == 2)
        let active = try #require(detours.first { $0.id == "DTR-5621" })
        #expect(active.isActive)
        #expect(active.version == 3)
        #expect(active.affected.count == 2)
        #expect(active.affected.contains(.init(route: "65", directionName: "Westbound")))
        #expect(active.beginsAt != nil)
        #expect(active.endsAt != nil)
        // Affects helper respects route+direction case-insensitively.
        #expect(active.affects(route: "65", direction: "westbound", at: active.beginsAt!.addingTimeInterval(3600)))
        #expect(!active.affects(route: "22", direction: "Northbound", at: active.beginsAt!.addingTimeInterval(3600)))

        let lifted = try #require(detours.first { $0.id == "DTR-5500" })
        #expect(!lifted.isActive)
        #expect(!lifted.affects(route: "22", direction: "Northbound", at: Date()))
    }
}
