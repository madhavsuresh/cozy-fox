import Foundation

public enum APIError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingAPIKey
    case invalidURL
    case http(status: Int)
    case decoding(String)
    case transport(String)
    case rateLimited

    public var description: String {
        switch self {
        case .missingAPIKey: "Missing API key"
        case .invalidURL: "Invalid URL"
        case .http(let status): "HTTP \(status)"
        case .decoding(let message): "Decoding failed: \(message)"
        case .transport(let message): "Network error: \(message)"
        case .rateLimited: "Rate limited"
        }
    }
}
