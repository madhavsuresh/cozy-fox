import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("Northwestern Intercampus decoder")
struct NorthwesternIntercampusClientTests {
    @Test func decodesIntercampusDirectionsAndStops() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = StubHTTPClient()
        await stub.register(
            path: "/v1/gtfs/realtime/tripUpdate",
            data: FeedBuilder.feed([
                FeedBuilder.tripUpdateEntity(
                    entityId: "north",
                    tripId: "north-trip",
                    routeId: "23174203-507c-48fe-811a-5d13fcf7be65",
                    stopId: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
                    arrivalAt: now.addingTimeInterval(300),
                    vehicleLabel: "35002"
                ),
                FeedBuilder.tripUpdateEntity(
                    entityId: "south",
                    tripId: "south-trip",
                    routeId: "ebee9228-c993-4279-b7ce-8fca0a46ca65",
                    stopId: "60e7b447-b29d-4812-bf93-7a77a1d5ae5b",
                    arrivalAt: now.addingTimeInterval(600),
                    vehicleLabel: "35003"
                ),
            ], timestamp: now)
        )
        let client = NorthwesternIntercampusClient(http: stub)

        let arrivals = try await client.fetchArrivals(stopIds: nil, now: now)

        #expect(arrivals.count == 2)
        #expect(arrivals.map(\.direction) == [.northbound, .southbound])
        #expect(arrivals[0].stopName == "Ward")
        #expect(arrivals[0].destinationName == "Evanston")
        #expect(arrivals[1].stopName == "Ryan Field")
        #expect(arrivals[1].destinationName == "Chicago")
    }

    @Test func filtersNonIntercampusRoutesAndRequestedStops() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stub = StubHTTPClient()
        await stub.register(
            path: "/v1/gtfs/realtime/tripUpdate",
            data: FeedBuilder.feed([
                FeedBuilder.tripUpdateEntity(
                    entityId: "wanted",
                    tripId: "wanted-trip",
                    routeId: "23174203-507c-48fe-811a-5d13fcf7be65",
                    stopId: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
                    arrivalAt: now.addingTimeInterval(300)
                ),
                FeedBuilder.tripUpdateEntity(
                    entityId: "wrong-stop",
                    tripId: "wrong-stop-trip",
                    routeId: "23174203-507c-48fe-811a-5d13fcf7be65",
                    stopId: "60e7b447-b29d-4812-bf93-7a77a1d5ae5b",
                    arrivalAt: now.addingTimeInterval(300)
                ),
                FeedBuilder.tripUpdateEntity(
                    entityId: "wrong-route",
                    tripId: "wrong-route-trip",
                    routeId: "not-intercampus",
                    stopId: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
                    arrivalAt: now.addingTimeInterval(300)
                ),
            ], timestamp: now)
        )
        let client = NorthwesternIntercampusClient(http: stub)

        let arrivals = try await client.fetchArrivals(
            stopIds: ["6983f6d3-fcd9-4932-b9fb-7120f8c2f999"],
            now: now
        )

        #expect(arrivals.count == 1)
        #expect(arrivals.first?.tripId == "wanted-trip")
    }
}

private enum FeedBuilder {
    static func feed(_ entities: [Data], timestamp: Date) -> Data {
        var data = Data()
        let header = stringField(1, "2.0") + varintField(3, UInt64(timestamp.timeIntervalSince1970))
        data.append(bytesField(1, header))
        for entity in entities {
            data.append(bytesField(2, entity))
        }
        return data
    }

    static func tripUpdateEntity(
        entityId: String,
        tripId: String,
        routeId: String,
        stopId: String,
        arrivalAt: Date,
        vehicleLabel: String? = nil
    ) -> Data {
        let trip = stringField(1, tripId) + stringField(5, routeId)
        let event = varintField(1, 0) + varintField(2, UInt64(arrivalAt.timeIntervalSince1970))
        let stopUpdate = bytesField(2, event) + stringField(4, stopId)
        var tripUpdate = bytesField(1, trip) + bytesField(2, stopUpdate)
        if let vehicleLabel {
            let vehicle = stringField(1, vehicleLabel) + stringField(2, vehicleLabel)
            tripUpdate.append(bytesField(3, vehicle))
        }
        tripUpdate.append(varintField(4, UInt64(arrivalAt.timeIntervalSince1970 - 30)))
        return stringField(1, entityId) + bytesField(3, tripUpdate)
    }

    private static func stringField(_ number: Int, _ value: String) -> Data {
        bytesField(number, Data(value.utf8))
    }

    private static func bytesField(_ number: Int, _ value: Data) -> Data {
        var data = varint(UInt64(number << 3 | 2))
        data.append(varint(UInt64(value.count)))
        data.append(value)
        return data
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        var data = varint(UInt64(number << 3))
        data.append(varint(value))
        return data
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var data = Data()
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }
}
