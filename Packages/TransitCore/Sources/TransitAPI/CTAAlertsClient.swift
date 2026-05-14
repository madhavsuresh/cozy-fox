import Foundation
import TransitModels

public protocol CTAAlertsClientProtocol: Sendable {
    func fetchActiveAlerts(forRoutes routes: [String]) async throws -> [ServiceAlert]
}

/// CTA Customer Alerts API. No auth required.
///
/// Docs: https://www.transitchicago.com/developers/alerts/
public actor CTAAlertsClient: CTAAlertsClientProtocol {
    public static let baseURL = URL(string: "https://www.transitchicago.com/api/1.0")!

    private let http: HTTPClient

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetchActiveAlerts(forRoutes routes: [String]) async throws -> [ServiceAlert] {
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("alerts.aspx"),
            resolvingAgainstBaseURL: false
        )!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "outputType", value: "JSON"),
            URLQueryItem(name: "activeonly", value: "true"),
        ]
        if !routes.isEmpty {
            items.append(URLQueryItem(name: "routeid", value: routes.joined(separator: ",")))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw APIError.invalidURL }
        let (data, response) = try await http.data(for: URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        do {
            let feed = try JSONDecoder.cta.decode(AlertsEnvelope.self, from: data)
            return (feed.CTAAlerts.Alert ?? []).compactMap { ServiceAlert(raw: $0) }
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

extension ServiceAlert {
    init?(raw: AlertsEnvelope.Body.Alert) {
        guard let begin = AlertFormatter.parse(raw.EventStart) else { return nil }
        let end = raw.EventEnd.flatMap { AlertFormatter.parse($0) }
        let severityFlag = (Int(raw.SeverityScore ?? "0") ?? 0)
        let severity: AlertSeverity = {
            switch severityFlag {
            case 0..<25: .low
            case 25..<55: .medium
            default: .high
            }
        }()
        let routes = (raw.ImpactedService?.services ?? []).compactMap { $0.ServiceId }
        let colors = routes.compactMap { LineColor(ctaRouteCode: $0) }
        let detailURL = raw.AlertURL?.url ?? Self.fallbackDetailURL(forAlertId: raw.AlertId)
        self.init(
            id: raw.AlertId,
            headline: raw.Headline,
            shortDescription: raw.ShortDescription ?? raw.Headline,
            severity: severity,
            impactedRoutes: routes,
            impactedLineColors: colors,
            beginsAt: begin,
            endsAt: end,
            isMajor: (raw.MajorAlert ?? "0") == "1",
            detailURL: detailURL
        )
    }

    /// CTA's alerts feed sometimes omits `AlertURL`. Their service-updates page
    /// accepts `?AlertId=` and links straight to the detail card, so we synthesize
    /// that URL as a fallback so every alert has a "more details" target.
    private static func fallbackDetailURL(forAlertId id: String) -> URL? {
        var comps = URLComponents(string: "https://www.transitchicago.com/travel-information/service-updates/alert/")
        comps?.queryItems = [URLQueryItem(name: "AlertId", value: id)]
        return comps?.url
    }
}

enum AlertFormatter {
    /// CTA's alerts feed mixes a few formats:
    ///   "2022-07-11T09:00:00"   (most alerts; ISO without timezone)
    ///   "2025-11-07"            (date-only, used when the start time is TBD)
    ///   "20260513 08:23:00"     (legacy compact format, still occasionally seen)
    /// We try each in turn so none of them silently drop the alert — which
    /// is what was happening before this and breaking the closed-stations
    /// filter (the State/Lake closure has a date-only start and was being
    /// thrown away by `compactMap`).
    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let compactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(_ value: String) -> Date? {
        isoFormatter.date(from: value)
            ?? dateOnlyFormatter.date(from: value)
            ?? compactFormatter.date(from: value)
    }
}

struct AlertsEnvelope: Decodable {
    let CTAAlerts: Body
    struct Body: Decodable {
        let TimeStamp: String?
        let ErrorCode: String?
        let ErrorMessage: String?
        let Alert: [Alert]?

        struct Alert: Decodable {
            let AlertId: String
            let Headline: String
            let ShortDescription: String?
            let SeverityScore: String?
            let MajorAlert: String?
            let EventStart: String
            let EventEnd: String?
            let ImpactedService: Impacted?
            let AlertURL: AlertURLValue?

            /// CTA's `AlertURL` decodes inconsistently: in some responses it's a
            /// bare string, in others it's an object wrapping a `URL` key (the
            /// XML-to-JSON shim leaks the wrapper through). Accept both shapes
            /// so neither variant silently drops the link.
            struct AlertURLValue: Decodable {
                let url: URL?

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let raw = try? container.decode(String.self) {
                        self.url = AlertURLValue.parse(raw)
                        return
                    }
                    let keyed = try decoder.container(keyedBy: CodingKeys.self)
                    let raw = try? keyed.decode(String.self, forKey: .URL)
                    self.url = raw.flatMap(AlertURLValue.parse)
                }

                private static func parse(_ raw: String) -> URL? {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    return URL(string: trimmed)
                }

                private enum CodingKeys: String, CodingKey { case URL }
            }

            struct Impacted: Decodable {
                // Property is `services` (lowercased + plural) so it doesn't
                // shadow the nested `Service` type inside the custom init.
                // The JSON key is still "Service" via CodingKeys.
                let services: [Service]

                // CTA's JSON serializes the Service field as an ARRAY when an
                // alert affects multiple routes/lines, but collapses to a
                // single OBJECT when only one is affected (~30/46 alerts in
                // any given snapshot). Swift's synthesized Decodable can't
                // accept both, so we hand-roll the init and silently fall
                // back to a single-element array. Previously this mismatch
                // would throw during decode, the error was swallowed by
                // `refreshAlerts`, and the entire alerts cache stayed empty —
                // which is why "closed" stations like State/Lake kept being
                // recommended.
                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    if let arr = try? c.decode([Service].self, forKey: .services) {
                        self.services = arr
                    } else if let one = try? c.decode(Service.self, forKey: .services) {
                        self.services = [one]
                    } else {
                        self.services = []
                    }
                }

                enum CodingKeys: String, CodingKey {
                    case services = "Service"
                }

                struct Service: Decodable {
                    let ServiceType: String?
                    let ServiceTypeDescription: String?
                    let ServiceId: String?
                    let ServiceName: String?
                }
            }
        }
    }
}
