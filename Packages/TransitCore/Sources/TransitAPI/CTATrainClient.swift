import Foundation
import TransitModels

public protocol CTATrainClientProtocol: Sendable {
    func fetchArrivals(mapId: Int, max: Int) async throws -> [Arrival]
    func fetchArrivals(stopId: Int, max: Int) async throws -> [Arrival]
    func fetchPositions(lines: [LineColor]) async throws -> [VehiclePosition]
}

/// CTA Train Tracker API. HTTP-only (needs ATS exception).
///
/// Docs: https://www.transitchicago.com/developers/ttdocs/
public actor CTATrainClient: CTATrainClientProtocol {
    public static let baseURL = URL(string: "http://lapi.transitchicago.com/api/1.0")!

    private let http: HTTPClient
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        http: HTTPClient = LiveHTTPClient(),
        apiKey: @Sendable @escaping () -> String?
    ) {
        self.http = http
        self.apiKeyProvider = apiKey
    }

    public func fetchArrivals(mapId: Int, max: Int = 8) async throws -> [Arrival] {
        try await fetchArrivals(query: [URLQueryItem(name: "mapid", value: String(mapId))], max: max)
    }

    public func fetchArrivals(stopId: Int, max: Int = 8) async throws -> [Arrival] {
        try await fetchArrivals(query: [URLQueryItem(name: "stpid", value: String(stopId))], max: max)
    }

    /// Live train positions for one or more L lines. Returns one entry per
    /// active run with its current lat/lon, next stop id, and destination.
    /// Source: https://www.transitchicago.com/developers/ttdocs/
    public func fetchPositions(lines: [LineColor]) async throws -> [VehiclePosition] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        guard !lines.isEmpty else { return [] }
        let routeCodes = lines.map(ctaRouteCode(for:)).joined(separator: ",")
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("ttpositions.aspx"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "rt", value: routeCodes),
            URLQueryItem(name: "outputType", value: "JSON"),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(TrainPositionsEnvelope.self, from: data)
            return (feed.ctatt.route ?? []).flatMap { route -> [VehiclePosition] in
                let lineRaw = LineColor(ctaRouteCode: route.name)?.rawValue ?? route.name
                return (route.train ?? []).compactMap { raw in
                    guard let lat = Double(raw.lat ?? ""),
                          let lon = Double(raw.lon ?? "") else { return nil }
                    return VehiclePosition(
                        id: raw.rn,
                        mode: .train,
                        route: lineRaw,
                        latitude: lat,
                        longitude: lon,
                        heading: Int(raw.heading ?? ""),
                        destinationName: raw.destNm,
                        nextStopId: Int(raw.nextStpId ?? ""),
                        observedAt: raw.prdt.flatMap(CTAFormatter.parse) ?? Date()
                    )
                }
            }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// CTA's `rt` parameter on the positions endpoint uses different codes
    /// than the arrivals endpoint expects.
    private nonisolated func ctaRouteCode(for line: LineColor) -> String {
        switch line {
        case .red:    "red"
        case .blue:   "blue"
        case .brown:  "brn"
        case .green:  "g"
        case .orange: "org"
        case .purple: "p"
        case .pink:   "pink"
        case .yellow: "y"
        }
    }

    private func fetchArrivals(query: [URLQueryItem], max: Int) async throws -> [Arrival] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("ttarrivals.aspx"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "max", value: String(max)),
            URLQueryItem(name: "outputType", value: "JSON"),
        ] + query
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(TrainArrivalsEnvelope.self, from: data)
            return (feed.ctatt.eta ?? []).compactMap { raw in
                Arrival(raw: raw)
            }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

extension JSONDecoder {
    static let cta: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - Mapping

extension Arrival {
    init?(raw: TrainArrivalsEnvelope.CTATT.ETA) {
        guard let line = LineColor(ctaRouteCode: raw.rt) else { return nil }
        guard
            let prdt = CTAFormatter.parse(raw.prdt),
            let arrT = CTAFormatter.parse(raw.arrT)
        else { return nil }
        self.init(
            id: "\(raw.rn)-\(raw.staId)-\(raw.arrT)",
            line: line,
            runNumber: raw.rn,
            destinationName: raw.destNm,
            stationId: Int(raw.staId) ?? 0,
            stationName: raw.staNm,
            stopId: Int(raw.stpId) ?? 0,
            directionCode: raw.trDr,
            predictedAt: prdt,
            arrivalAt: arrT,
            isApproaching: raw.isApp == "1",
            isDelayed: raw.isDly == "1",
            isFault: raw.isFlt == "1",
            isScheduled: raw.isSch == "1"
        )
    }
}

// MARK: - Wire types

// MARK: - Positions wire types

struct TrainPositionsEnvelope: Decodable {
    let ctatt: CTATT
    struct CTATT: Decodable {
        let tmst: String?
        let errCd: String?
        let errNm: String?
        let route: [Route]?
        struct Route: Decodable {
            let name: String           // "red", "blue", …
            let train: [Train]?
            enum CodingKeys: String, CodingKey {
                case name = "@name"
                case train
            }
            struct Train: Decodable {
                let rn: String         // run number
                let destSt: String?
                let destNm: String?
                let trDr: String?
                let nextStaId: String?
                let nextStpId: String?
                let nextStaNm: String?
                let prdt: String?
                let arrT: String?
                let isApp: String?
                let isDly: String?
                let lat: String?
                let lon: String?
                let heading: String?
            }
        }
    }
}

struct TrainArrivalsEnvelope: Decodable {
    let ctatt: CTATT
    struct CTATT: Decodable {
        let tmst: String?
        let errCd: String?
        let errNm: String?
        let eta: [ETA]?
        struct ETA: Decodable {
            let staId: String
            let stpId: String
            let staNm: String
            let stpDe: String?
            let rn: String
            let rt: String
            let destSt: String
            let destNm: String
            let trDr: String
            let prdt: String
            let arrT: String
            let isApp: String
            let isSch: String
            let isDly: String
            let isFlt: String
        }
    }
}

enum CTAFormatter {
    /// CTA timestamps look like "2026-05-13T08:23:00" in local time (Chicago).
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ value: String) -> Date? { formatter.date(from: value) }
}
