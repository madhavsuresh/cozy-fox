import Foundation
import TransitModels

public protocol CTABusClientProtocol: Sendable {
    func fetchPredictions(route: String, stopId: Int, top: Int) async throws -> [BusPrediction]
    func fetchVehicles(routes: [String]) async throws -> [VehiclePosition]
    func fetchDetours(routes: [String]) async throws -> [BusDetour]
    func fetchPatterns(routes: [String]) async throws -> [BusPattern]
    func fetchStopDetourStates(stopIds: [Int]) async throws -> [BusStopDetourState]
}

/// CTA Bus Tracker API v2 (with one phase 2b call against v3 for the
/// per-stop `dtradd` / `dtrrem` fields that v2 doesn't expose).
///
/// Docs: https://www.transitchicago.com/developers/bustracker/
public actor CTABusClient: CTABusClientProtocol {
    public static let baseURL = URL(string: "https://ctabustracker.com/bustime/api/v2")!
    /// v3 surface, used today only for `getstops` so we can read each
    /// stop's `dtradd` / `dtrrem` detour-membership arrays. The rest of
    /// the client stays on v2 — switching the whole client over is a
    /// separate cleanup.
    public static let v3BaseURL = URL(string: "https://ctabustracker.com/bustime/api/v3")!

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
                    patternId: raw.pid,
                    patternDistanceFeet: raw.pdist.map(Double.init),
                    observedAt: Date()
                )
            }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Pattern geometry (`pid`, points, distances) for one or more routes.
    /// Used in phase 3 for along-pattern remaining-distance scoring and
    /// already-crossed-stop detection. Patterns change rarely (only when
    /// detours alter geometry), so callers should refresh hourly at most.
    public func fetchPatterns(routes: [String]) async throws -> [BusPattern] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        guard !routes.isEmpty else { return [] }
        var collected: [BusPattern] = []
        // `getpatterns` accepts either a single `rt` or up to 10 `pid`.
        // Single-route calls are simpler and stay well inside daily caps
        // because the user's pinned set is small (typically < 10 routes).
        for route in routes {
            var comps = URLComponents(
                url: Self.baseURL.appendingPathComponent("getpatterns"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "rt", value: route),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = comps.url else { throw APIError.invalidURL }
            let (data, response) = try await http.data(for: URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else {
                throw APIError.http(status: response.statusCode)
            }
            let feed = try JSONDecoder.cta.decode(BusPatternsEnvelope.self, from: data)
            let patterns = (feed.bustimeResponse.ptr ?? []).compactMap {
                BusPattern(raw: $0, route: route)
            }
            collected.append(contentsOf: patterns)
        }
        return collected
    }

    /// Per-stop detour membership for `stopIds` (up to 10 per call; the
    /// implementation chunks larger lists). Reads CTA v3 `getstops` and
    /// extracts the `dtradd` / `dtrrem` arrays — phase 2b needs these to
    /// know which stops a currently-active detour actually skips.
    public func fetchStopDetourStates(stopIds: [Int]) async throws -> [BusStopDetourState] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        guard !stopIds.isEmpty else { return [] }
        // CTA caps `stpid` at 10 per call.
        let chunks = stride(from: 0, to: stopIds.count, by: 10).map {
            Array(stopIds[$0..<min($0 + 10, stopIds.count)])
        }
        var collected: [BusStopDetourState] = []
        for chunk in chunks {
            var comps = URLComponents(
                url: Self.v3BaseURL.appendingPathComponent("getstops"),
                resolvingAgainstBaseURL: false
            )!
            comps.queryItems = [
                URLQueryItem(name: "key", value: key),
                URLQueryItem(name: "stpid", value: chunk.map(String.init).joined(separator: ",")),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = comps.url else { throw APIError.invalidURL }
            let (data, response) = try await http.data(for: URLRequest(url: url))
            guard (200..<300).contains(response.statusCode) else {
                throw APIError.http(status: response.statusCode)
            }
            let feed = try JSONDecoder.cta.decode(BusStopsEnvelope.self, from: data)
            let states = (feed.bustimeResponse.stops ?? []).compactMap {
                BusStopDetourState(raw: $0)
            }
            collected.append(contentsOf: states)
        }
        return collected
    }

    /// Active and recently canceled detours, optionally filtered to a set of
    /// routes. CTA's `getdetours` accepts a comma-separated `rt` parameter
    /// just like `getvehicles`; pass an empty array to receive everything.
    ///
    /// Docs: https://www.transitchicago.com/developers/bustracker/
    public func fetchDetours(routes: [String]) async throws -> [BusDetour] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("getdetours"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "format", value: "json"),
        ]
        if !routes.isEmpty {
            items.append(URLQueryItem(name: "rt", value: routes.joined(separator: ",")))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(BusDetoursEnvelope.self, from: data)
            return (feed.bustimeResponse.dtr ?? []).compactMap { BusDetour(raw: $0) }
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

    /// `getdetours` includes seconds on its `startdt` / `enddt` timestamps;
    /// `getpredictions` does not.
    static let formatterWithSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ value: String) -> Date? {
        formatterWithSeconds.date(from: value) ?? formatter.date(from: value)
    }
}

extension BusDetour {
    init?(raw: BusDetoursEnvelope.Body.Detour) {
        let affected = (raw.rtdirs ?? []).map {
            BusDetour.RouteDirection(route: $0.rt, directionName: $0.dir)
        }
        self.init(
            id: raw.id,
            version: raw.ver ?? 0,
            isActive: (raw.st ?? 0) == 1,
            summary: raw.desc ?? "",
            affected: affected,
            beginsAt: raw.startdt.flatMap(CTABusFormatter.parse),
            endsAt: raw.enddt.flatMap(CTABusFormatter.parse)
        )
    }
}

extension BusPattern {
    init?(raw: BusPatternsEnvelope.Body.Pattern, route: String) {
        let points: [BusPatternPoint] = (raw.pt ?? []).compactMap { p in
            guard let lat = p.lat, let lon = p.lon, let pdist = p.pdist else { return nil }
            let stopIdInt: Int?
            switch p.stpid {
            case .some(.int(let n)): stopIdInt = n
            case .some(.string(let s)): stopIdInt = Int(s)
            case .none: stopIdInt = nil
            }
            return BusPatternPoint(
                sequence: p.seq ?? 0,
                latitude: lat,
                longitude: lon,
                patternDistanceFeet: pdist,
                kindRaw: p.typ,
                stopId: stopIdInt,
                stopName: p.stpnm
            )
        }
        guard !points.isEmpty else { return nil }
        self.init(
            id: raw.pid,
            route: route,
            directionName: raw.rtdir ?? "",
            lengthFeet: raw.ln,
            detourId: raw.dtrid,
            points: points.sorted { $0.sequence < $1.sequence }
        )
    }
}

struct BusPatternsEnvelope: Decodable {
    let bustimeResponse: Body
    enum CodingKeys: String, CodingKey { case bustimeResponse = "bustime-response" }

    struct Body: Decodable {
        let ptr: [Pattern]?
        let error: [BusPredictionsEnvelope.Body.Err]?

        struct Pattern: Decodable {
            let pid: Int
            let ln: Double?
            let rtdir: String?
            let dtrid: String?
            let pt: [Point]?

            struct Point: Decodable {
                let seq: Int?
                let lat: Double?
                let lon: Double?
                let typ: String?
                let stpid: StringOrInt?
                let stpnm: String?
                let pdist: Double?
            }
        }
    }
}

/// CTA's bus tracker mixes integer and string typings for stop IDs across
/// endpoints; the patterns feed in particular sometimes returns integers
/// where predictions returns strings. Single decoder handles both.
enum StringOrInt: Decodable {
    case int(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            StringOrInt.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected Int or String")
        )
    }
}

extension BusStopDetourState {
    init?(raw: BusStopsEnvelope.Body.Stop) {
        let stpidString: String
        switch raw.stpid {
        case .int(let n): stpidString = String(n)
        case .string(let s): stpidString = s
        }
        guard let stopId = Int(stpidString) else { return nil }
        self.init(
            stopId: stopId,
            addedByDetourIds: raw.dtradd ?? [],
            removedByDetourIds: raw.dtrrem ?? []
        )
    }
}

struct BusStopsEnvelope: Decodable {
    let bustimeResponse: Body
    enum CodingKeys: String, CodingKey { case bustimeResponse = "bustime-response" }

    struct Body: Decodable {
        let stops: [Stop]?
        let error: [BusPredictionsEnvelope.Body.Err]?

        struct Stop: Decodable {
            let stpid: StringOrInt
            let stpnm: String?
            let lat: Double?
            let lon: Double?
            let dtradd: [String]?
            let dtrrem: [String]?
        }
    }
}

struct BusDetoursEnvelope: Decodable {
    let bustimeResponse: Body
    enum CodingKeys: String, CodingKey { case bustimeResponse = "bustime-response" }

    struct Body: Decodable {
        let dtr: [Detour]?
        let error: [BusPredictionsEnvelope.Body.Err]?

        struct Detour: Decodable {
            let id: String
            let ver: Int?
            let st: Int?
            let desc: String?
            let rtdirs: [RouteDirection]?
            let startdt: String?
            let enddt: String?

            struct RouteDirection: Decodable {
                let rt: String
                let dir: String
            }
        }
    }
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
            let pid: Int?
            let pdist: Int?
            let rt: String
            let des: String?
            let spd: Int?
            let dly: Bool?

            // CTA Bus Tracker v2 returns `pid` and `pdist` as JSON
            // strings for some endpoints/versions, JSON numbers for
            // others. Decoding either as a strict `Int?` killed the
            // whole envelope decode whenever CTA chose strings, which
            // wiped out every bus vehicle and caused phase 1's
            // `vehicleNotFound` abstain to hide every imminent
            // prediction. The custom init falls back through both
            // types and strips whitespace before parsing strings.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                vid = try c.decode(String.self, forKey: .vid)
                lat = try c.decodeIfPresent(String.self, forKey: .lat)
                lon = try c.decodeIfPresent(String.self, forKey: .lon)
                hdg = try c.decodeIfPresent(String.self, forKey: .hdg)
                pid = Self.decodeFlexibleInt(c, forKey: .pid)
                pdist = Self.decodeFlexibleInt(c, forKey: .pdist)
                rt = try c.decode(String.self, forKey: .rt)
                des = try c.decodeIfPresent(String.self, forKey: .des)
                spd = try c.decodeIfPresent(Int.self, forKey: .spd)
                dly = try c.decodeIfPresent(Bool.self, forKey: .dly)
            }

            private static func decodeFlexibleInt(
                _ container: KeyedDecodingContainer<CodingKeys>,
                forKey key: CodingKeys
            ) -> Int? {
                if let i = try? container.decodeIfPresent(Int.self, forKey: key) {
                    return i
                }
                if let s = try? container.decodeIfPresent(String.self, forKey: key) {
                    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return nil
            }

            enum CodingKeys: String, CodingKey {
                case vid, lat, lon, hdg, pid, pdist, rt, des, spd, dly
            }
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
