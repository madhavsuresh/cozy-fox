import Foundation

/// Tiny seam over URLSession so tests can inject fixtures.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct LiveHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.transport("Non-HTTP response")
            }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    /// A URLSession that is reasonable for CTA / Divvy fetches: short timeouts,
    /// a small URLCache for back-to-back retries, no cookies.
    public static func makeSharedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(
            memoryCapacity: 4 * 1024 * 1024,
            diskCapacity: 0,
            directory: nil
        )
        config.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: config)
    }
}

/// Transparent retry wrapper. Re-attempts on transport errors and 5xx
/// responses with a short backoff so a single flaky fetch doesn't surface as
/// "no data" in the UI. Honors `APIError.rateLimited` and 4xx as terminal.
public struct RetryingHTTPClient: HTTPClient {
    public let inner: HTTPClient
    public let maxAttempts: Int
    public let baseBackoff: TimeInterval

    public init(inner: HTTPClient, maxAttempts: Int = 2, baseBackoff: TimeInterval = 0.4) {
        self.inner = inner
        self.maxAttempts = max(1, maxAttempts)
        self.baseBackoff = max(0, baseBackoff)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = APIError.transport("No attempts made")
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await inner.data(for: request)
                if (500...599).contains(response.statusCode), attempt < maxAttempts - 1 {
                    lastError = APIError.http(status: response.statusCode)
                    try? await Task.sleep(nanoseconds: backoffNanos(for: attempt))
                    continue
                }
                return (data, response)
            } catch let error as APIError {
                lastError = error
                guard Self.isRetryable(error), attempt < maxAttempts - 1 else { throw error }
                try? await Task.sleep(nanoseconds: backoffNanos(for: attempt))
            } catch {
                lastError = error
                guard attempt < maxAttempts - 1 else { throw error }
                try? await Task.sleep(nanoseconds: backoffNanos(for: attempt))
            }
        }
        throw lastError
    }

    private func backoffNanos(for attempt: Int) -> UInt64 {
        let seconds = min(2.0, baseBackoff * pow(2.0, Double(attempt)))
        return UInt64(seconds * 1_000_000_000)
    }

    private static func isRetryable(_ error: APIError) -> Bool {
        switch error {
        case .transport: return true
        case .http(let status) where (500...599).contains(status): return true
        case .http, .decoding, .invalidURL, .missingAPIKey, .rateLimited: return false
        }
    }
}
