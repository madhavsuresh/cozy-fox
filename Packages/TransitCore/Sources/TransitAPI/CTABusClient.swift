import Foundation
import TransitModels

public protocol CTABusClientProtocol: Sendable {
    func fetchPredictions(route: String, stopId: Int, top: Int) async throws -> [BusPrediction]
    func fetchVehicles(routes: [String]) async throws -> [VehiclePosition]
}

/// CTA Bus Tracker API v2.
///
/// Docs: https://www.transitchicago.com/developers/bustracker/
public actor CTABusClient: CTABusClientProtocol {
    public static let baseURL = URL(string: "https://ctabustracker.com/bustime/api/v2")!

    private let http: HTTPClient
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        http: HTTPClient = LiveHTTPClient(),
        apiKey: @Sendable @escaping () -> String?
    ) {
        self.http = http
        self.apiKeyProvider = apiKey
    }

    /// Live bus vehicle positions for one or more routes.
    /// Source: https://www.transitchicago.com/developers/bustracker/
    public func fetchVehicles(routes: [String]) async throws -> [VehiclePosition] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        guard !routes.isEmpty else { return [] }
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("getvehicles"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "rt", value: routes.joined(separator: ",")),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(BusVehiclesEnvelope.self, from: data)
            return (feed.bustimeResponse.vehicle ?? []).compactMap { raw in
                guard let lat = Double(raw.lat ?? ""),
                      let lon = Double(raw.lon ?? "") else { return nil }
                return VehiclePosition(
                    id: raw.vid,
                    mode: .bus,
                    route: raw.rt,
                    latitude: lat,
                    longitude: lon,
                    heading: Int(raw.hdg ?? ""),
                    destinationName: raw.des,
                    nextStopId: nil,
                    observedAt: Date()
                )
            }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func fetchPredictions(route: String, stopId: Int, top: Int = 4) async throws -> [BusPrediction] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("getpredictions"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "rt", value: route),
            URLQueryItem(name: "stpid", value: String(stopId)),
            URLQueryItem(name: "top", value: String(top)),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(BusPredictionsEnvelope.self, from: data)
            return (feed.bustimeResponse.prd ?? []).compactMap { BusPrediction(raw: $0) }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

extension BusPrediction {
    init?(raw: BusPredictionsEnvelope.Body.Prediction) {
        guard
            let generated = CTABusFormatter.parse(raw.tmstmp),
            let arrival = CTABusFormatter.parse(raw.prdtm)
        else { return nil }
        self.init(
            id: "\(raw.vid)-\(raw.stpid)-\(raw.prdtm)",
            route: raw.rt,
            routeName: raw.rtdir,
            vehicleId: raw.vid,
            stopId: Int(raw.stpid) ?? 0,
            stopName: raw.stpnm,
            destinationName: raw.des,
            directionName: raw.rtdir,
            generatedAt: generated,
            arrivalAt: arrival,
            isDelayed: raw.dly ?? false,
            isApproaching: (Int(raw.prdctdn) ?? 99) <= 1
        )
    }
}

enum CTABusFormatter {
    /// Bus Tracker uses "20260513 08:23" — no colon between date and time.
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HH:mm"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ value: String) -> Date? { formatter.date(from: value) }
}

struct BusVehiclesEnvelope: Decodable {
    let bustimeResponse: Body
    enum CodingKeys: String, CodingKey { case bustimeResponse = "bustime-response" }

    struct Body: Decodable {
        let vehicle: [Vehicle]?
        let error: [BusPredictionsEnvelope.Body.Err]?

        struct Vehicle: Decodable {
            let vid: String
            let lat: String?
            let lon: String?
            let hdg: String?
            let rt: String
            let des: String?
            let spd: Int?
            let dly: Bool?
        }
    }
}

struct BusPredictionsEnvelope: Decodable {
    let bustimeResponse: Body
    enum CodingKeys: String, CodingKey { case bustimeResponse = "bustime-response" }

    struct Body: Decodable {
        let prd: [Prediction]?
        let error: [Err]?

        struct Prediction: Decodable {
            let tmstmp: String
            let typ: String
            let stpnm: String
            let stpid: String
            let vid: String
            let dstp: Int?
            let rt: String
            let rtdir: String
            let des: String
            let prdtm: String
            let dly: Bool?
            let prdctdn: String
        }

        struct Err: Decodable {
            let rt: String?
            let stpid: String?
            let msg: String
        }
    }
}
