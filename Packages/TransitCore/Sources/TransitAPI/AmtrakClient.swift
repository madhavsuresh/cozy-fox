import Foundation
import TransitModels

public protocol AmtrakClientProtocol: Sendable {
    func fetchLiveUpdates() async throws -> [AmtrakRealtimeUpdate]
    func fetchServiceNotices() async throws -> [ServiceAlert]
}

/// Official Amtrak data client.
///
/// Schedules come from the bundled static GTFS catalog. Amtrak does not expose
/// a documented, stable direct GTFS-realtime endpoint here, so live updates
/// intentionally return an empty set until an official direct source is
/// validated.
public actor AmtrakClient: AmtrakClientProtocol {
    private let http: HTTPClient

    private static let noticesURL = URL(string: "https://www.amtrak.com/service-alerts-and-notices")!

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetchLiveUpdates() async throws -> [AmtrakRealtimeUpdate] {
        []
    }

    public func fetchServiceNotices() async throws -> [ServiceAlert] {
        var request = URLRequest(url: Self.noticesURL)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw APIError.decoding("Amtrak notices response was not UTF-8")
        }
        return AmtrakNoticeParser.parse(html: html, fetchedAt: .now)
    }
}

enum AmtrakNoticeParser {
    static func parse(html: String, fetchedAt: Date) -> [ServiceAlert] {
        let blocks = noticeBlocks(in: html)
        let parsed = blocks.compactMap { block -> ServiceAlert? in
            let heading = firstMatch(
                pattern: #"<h[1-6][^>]*>(.*?)</h[1-6]>"#,
                in: block
            ).map(cleanText)
            let text = cleanText(block)
            let headline = (heading?.isEmpty == false ? heading : firstSentence(in: text))
                ?? "Amtrak service notice"
            guard !headline.isEmpty, text.count >= 20 else { return nil }
            let routes = impactedRoutes(in: "\(headline) \(text)")
            return ServiceAlert(
                id: "amtrak-\(stableID(for: headline + text))",
                headline: headline,
                shortDescription: text,
                severity: severity(in: text),
                provider: .amtrak,
                sourceLabel: "Notice",
                impactedRoutes: routes,
                impactedLineColors: [],
                beginsAt: fetchedAt.addingTimeInterval(-60),
                endsAt: nil,
                isMajor: severity(in: text) == .high,
                detailURL: ServiceAlert.amtrakDetailsURL
            )
        }

        var seen: Set<String> = []
        return parsed.filter { seen.insert($0.id).inserted }
    }

    private static func noticeBlocks(in html: String) -> [String] {
        let explicitBlocks = matches(
            pattern: #"<(?:article|section|li|div)[^>]*(?:alert|notice|service-alert)[^>]*>.*?</(?:article|section|li|div)>"#,
            in: html
        )
        if !explicitBlocks.isEmpty { return explicitBlocks }

        let headingSections = matches(
            pattern: #"<h[2-4][^>]*>.*?</h[2-4]>(?:(?!<h[2-4][^>]*>).){0,2500}"#,
            in: html
        )
        return headingSections.filter { block in
            let text = cleanText(block).lowercased()
            return text.contains("amtrak") || text.contains("service") || text.contains("train")
        }
    }

    private static func impactedRoutes(in text: String) -> [String] {
        let lower = text.lowercased()
        return AmtrakStationCatalog.routes.compactMap { route -> String? in
            let long = route.longName.lowercased()
            let short = route.shortName.lowercased()
            if !long.isEmpty, lower.contains(long) { return route.id }
            if !short.isEmpty, lower.contains(short) { return route.id }
            return nil
        }
        .uniqued()
        .sorted()
    }

    private static func severity(in text: String) -> AlertSeverity {
        let lower = text.lowercased()
        if lower.contains("cancel") || lower.contains("suspended") || lower.contains("no service") {
            return .high
        }
        if lower.contains("delay") || lower.contains("modified") || lower.contains("disruption") {
            return .medium
        }
        return .low
    }

    private static func firstSentence(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let period = trimmed.firstIndex(of: ".") {
            return String(trimmed[...period])
        }
        return String(trimmed.prefix(140))
    }

    private static func cleanText(_ html: String) -> String {
        let withoutScripts = replace(
            pattern: #"<(script|style)[^>]*>.*?</\1>"#,
            in: html,
            with: " "
        )
        let withoutTags = replace(pattern: #"<[^>]+>"#, in: withoutScripts, with: " ")
        let decoded = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return decoded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private static func stableID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
