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
}
