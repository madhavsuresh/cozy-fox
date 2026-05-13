import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("CTA Train Tracker decoder")
struct CTATrainClientTests {
    @Test func decodesArrivalsAndMapsLineColor() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/api/1.0/ttarrivals.aspx",
            data: Fixture.load("cta_train_arrivals")
        )
        let client = CTATrainClient(http: stub) { "stub-key" }
        let arrivals = try await client.fetchArrivals(mapId: 40380, max: 8)

        #expect(arrivals.count == 2)
        let first = try #require(arrivals.first)
        #expect(first.line == .red)
        #expect(first.runNumber == "418")
        #expect(first.destinationName == "95th/Dan Ryan")
        #expect(first.stationId == 40380)

        let second = arrivals[1]
        #expect(second.isDelayed)
    }

    @Test func missingKeyThrows() async throws {
        let stub = StubHTTPClient()
        let client = CTATrainClient(http: stub) { nil }
        await #expect(throws: APIError.self) {
            _ = try await client.fetchArrivals(mapId: 40380)
        }
    }
}
