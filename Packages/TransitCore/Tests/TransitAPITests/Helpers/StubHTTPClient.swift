import Foundation
@testable import TransitAPI

/// Returns canned responses by URL path. Lets us hit a "GBFS" or "CTA" client
/// without ever touching the network in tests.
public actor StubHTTPClient: HTTPClient {
    private var responses: [String: (data: Data, status: Int)] = [:]

    public init() {}

    public func register(path: String, data: Data, status: Int = 200) {
        responses[path] = (data, status)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
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

public enum Fixture {
    public static func load(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        else {
            fatalError("Missing fixture: \(name).json")
        }
        return (try? Data(contentsOf: url)) ?? Data()
    }
}
