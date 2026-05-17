import Foundation
import Testing
@testable import TransitAPI

@Suite("RetryingHTTPClient")
struct RetryingHTTPClientTests {

    /// Mutable, queue-driven HTTP stub. Each call pops the next scripted
    /// outcome so we can stage "fail, fail, succeed" sequences.
    private actor ScriptedHTTPClient: HTTPClient {
        enum Outcome {
            case throwingTransport(String)
            case throwingHTTP(status: Int)
            case throwingDecoding(String)
            case throwingRateLimited
            case status(Int)
        }

        private var queue: [Outcome]
        private(set) var callCount: Int = 0

        init(script: [Outcome]) {
            self.queue = script
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            callCount += 1
            let outcome = queue.isEmpty ? .status(200) : queue.removeFirst()
            switch outcome {
            case .throwingTransport(let msg):
                throw APIError.transport(msg)
            case .throwingHTTP(let status):
                throw APIError.http(status: status)
            case .throwingDecoding(let msg):
                throw APIError.decoding(msg)
            case .throwingRateLimited:
                throw APIError.rateLimited
            case .status(let status):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (Data(), response)
            }
        }
    }

    private static let zeroBackoff: TimeInterval = 0

    @Test func transportFailureRetriesAndSucceeds() async throws {
        let inner = ScriptedHTTPClient(script: [
            .throwingTransport("connection lost"),
            .status(200),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 2, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (_, response) = try await retrying.data(for: request)
        #expect(response.statusCode == 200)
        #expect(await inner.callCount == 2)
    }

    @Test func fiveHundredResponseRetries() async throws {
        let inner = ScriptedHTTPClient(script: [
            .status(503),
            .status(200),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 2, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (_, response) = try await retrying.data(for: request)
        #expect(response.statusCode == 200)
        #expect(await inner.callCount == 2)
    }

    @Test func fourHundredResponseDoesNotRetry() async throws {
        let inner = ScriptedHTTPClient(script: [
            .status(404),
            .status(200),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 3, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (_, response) = try await retrying.data(for: request)
        #expect(response.statusCode == 404)
        #expect(await inner.callCount == 1)
    }

    @Test func rateLimitedErrorDoesNotRetry() async throws {
        let inner = ScriptedHTTPClient(script: [
            .throwingRateLimited,
            .status(200),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 3, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        do {
            _ = try await retrying.data(for: request)
            Issue.record("Expected rateLimited to propagate")
        } catch let error as APIError {
            #expect(error == .rateLimited)
        }
        #expect(await inner.callCount == 1)
    }

    @Test func decodingErrorDoesNotRetry() async throws {
        let inner = ScriptedHTTPClient(script: [
            .throwingDecoding("bad json"),
            .status(200),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 3, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        do {
            _ = try await retrying.data(for: request)
            Issue.record("Expected decoding error to propagate")
        } catch let error as APIError {
            if case .decoding = error { } else { Issue.record("Wrong APIError variant: \(error)") }
        }
        #expect(await inner.callCount == 1)
    }

    @Test func allAttemptsFailPropagatesLastError() async throws {
        let inner = ScriptedHTTPClient(script: [
            .throwingTransport("first"),
            .throwingTransport("second"),
        ])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 2, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        do {
            _ = try await retrying.data(for: request)
            Issue.record("Expected transport failure")
        } catch let error as APIError {
            #expect(error == .transport("second"))
        }
        #expect(await inner.callCount == 2)
    }

    @Test func happyPathStaysSingleCall() async throws {
        let inner = ScriptedHTTPClient(script: [.status(200)])
        let retrying = RetryingHTTPClient(inner: inner, maxAttempts: 3, baseBackoff: Self.zeroBackoff)
        let request = URLRequest(url: URL(string: "https://example.com")!)
        let (_, response) = try await retrying.data(for: request)
        #expect(response.statusCode == 200)
        #expect(await inner.callCount == 1)
    }
}
