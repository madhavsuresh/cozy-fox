import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("Divvy GBFS decoder")
struct DivvyGBFSClientTests {
    @Test func decodesStationsAndMergesInfoWithStatus() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/gbfs/2.3/chi/en/station_information.json",
            data: Fixture.load("divvy_station_information")
        )
        await stub.register(
            path: "/gbfs/2.3/chi/en/station_status.json",
            data: Fixture.load("divvy_station_status")
        )
        let client = DivvyGBFSClient(http: stub)
        let stations = try await client.fetchStations()

        #expect(stations.count == 2)
        let wabash = try #require(stations.first { $0.id == "2056421762206241370" })
        #expect(wabash.name == "Wabash Ave & Grand Ave")
        #expect(wabash.eBikesAvailable == 1)
        #expect(wabash.docksAvailable == 9)
        #expect(wabash.isRenting)

        let clark = try #require(stations.first { $0.id == "2212612309299256224" })
        #expect(clark.eBikesAvailable == 5)
        #expect(!clark.isScarce)
        #expect(wabash.isScarce, "1 e-bike must be flagged as scarce")
    }

    @Test func filtersToElectricBikesAndDropsDisabled() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/gbfs/2.3/chi/en/free_bike_status.json",
            data: Fixture.load("divvy_free_bike_status")
        )
        await stub.register(
            path: "/gbfs/2.3/chi/en/vehicle_types.json",
            data: Fixture.load("divvy_vehicle_types")
        )
        let client = DivvyGBFSClient(http: stub)
        let bikes = try await client.fetchEBikes()

        #expect(bikes.count == 2, "classic bike + disabled bike should be excluded")
        #expect(bikes.allSatisfy { $0.currentRangeMeters > 0 })
        let ranges = bikes.map(\.currentRangeMeters)
        #expect(ranges.contains(where: { abs($0 - 54878.63) < 0.01 }))
    }

    @Test func liveAvailabilityFeedsBypassLocalCache() async throws {
        let stub = RecordingHTTPClient()
        await stub.register(
            path: "/gbfs/2.3/chi/en/station_information.json",
            data: Fixture.load("divvy_station_information")
        )
        await stub.register(
            path: "/gbfs/2.3/chi/en/station_status.json",
            data: Fixture.load("divvy_station_status")
        )
        await stub.register(
            path: "/gbfs/2.3/chi/en/free_bike_status.json",
            data: Fixture.load("divvy_free_bike_status")
        )
        await stub.register(
            path: "/gbfs/2.3/chi/en/vehicle_types.json",
            data: Fixture.load("divvy_vehicle_types")
        )

        let client = DivvyGBFSClient(http: stub)
        _ = try await client.fetchStations()
        _ = try await client.fetchEBikes()

        let requestsByName = Dictionary(
            uniqueKeysWithValues: await stub.recordedRequests().map { ($0.fileName, $0) }
        )
        let stationStatus = try #require(requestsByName["station_status.json"])
        let freeBikeStatus = try #require(requestsByName["free_bike_status.json"])

        #expect(stationStatus.bypassesLocalCache)
        #expect(stationStatus.cacheControl == "no-cache")
        #expect(stationStatus.pragma == "no-cache")
        #expect(freeBikeStatus.bypassesLocalCache)
        #expect(freeBikeStatus.cacheControl == "no-cache")
        #expect(freeBikeStatus.pragma == "no-cache")
        #expect(requestsByName["station_information.json"]?.bypassesLocalCache == false)
        #expect(requestsByName["vehicle_types.json"]?.bypassesLocalCache == false)
    }
}

private struct RecordedRequest: Sendable {
    let fileName: String
    let bypassesLocalCache: Bool
    let cacheControl: String?
    let pragma: String?
}

private actor RecordingHTTPClient: HTTPClient {
    private var responses: [String: (data: Data, status: Int)] = [:]
    private var requests: [RecordedRequest] = []

    func register(path: String, data: Data, status: Int = 200) {
        responses[path] = (data, status)
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        requests.append(
            RecordedRequest(
                fileName: request.url?.lastPathComponent ?? "",
                bypassesLocalCache: request.cachePolicy == .reloadIgnoringLocalCacheData,
                cacheControl: request.value(forHTTPHeaderField: "Cache-Control"),
                pragma: request.value(forHTTPHeaderField: "Pragma")
            )
        )
        guard let response = responses[path] else {
            throw APIError.http(status: 404)
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response.data, http)
    }
}
