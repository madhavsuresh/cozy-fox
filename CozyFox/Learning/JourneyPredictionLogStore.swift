import Foundation
import TransitDomain
import TransitModels

/// Append-only NDJSON log of departure-ladder predictions for offline
/// calibration. One record per `appendEpisode` call. Lives in the app's
/// Caches directory — never leaves the device. Rotates at 5MB.
actor JourneyPredictionLogStore {
    private let baseURL: URL
    private let activeURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil, maxBytes: Int = 5 * 1024 * 1024) {
        let caches = directory ?? Self.defaultDirectory
        self.baseURL = caches
        self.activeURL = caches.appendingPathComponent("journey-predictions.ndjson")
        self.rotatedURL = caches.appendingPathComponent("journey-predictions.1.ndjson")
        self.maxBytes = maxBytes
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    }

    func appendEpisode(_ episode: JourneyEpisodeLog) {
        guard let line = try? encoder.encode(episode) else { return }
        let payload = line + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: activeURL.path) {
            FileManager.default.createFile(atPath: activeURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: activeURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } catch {
            return
        }
        rotateIfNeeded()
    }

    /// File URL of the active log, exposed for debug surfaces.
    func activeLogURL() -> URL { activeURL }

    func appendLadder(_ ladder: DepartureLadder, sessionID: UUID = UUID(), origin: String? = nil) {
        let entries: [PredictionLogEntry] = ladder.rows.map { row in
            let payload: [String: String] = [
                "leaveByAt": ISO8601DateFormatter().string(from: row.leaveByAt),
                "arrivalLow": ISO8601DateFormatter().string(from: row.arrivalAt.low),
                "arrivalHigh": ISO8601DateFormatter().string(from: row.arrivalAt.high),
                "durationP50Seconds": String(format: "%.1f", row.totalDuration.p50),
                "durationP80Seconds": String(format: "%.1f", row.totalDuration.p80),
                "durationP90Seconds": String(format: "%.1f", row.totalDuration.p90),
                "primaryLabel": row.primaryLabel,
                "secondaryLabel": row.secondaryLabel ?? "",
                "riskRawValue": row.risk.rawValue,
                "catchProbability": String(format: "%.3f", row.catchProbability),
                "missCostSeconds": row.missCostSeconds.map { String(format: "%.1f", $0) } ?? ""
            ]
            let payloadString = payloadJSON(payload)
            return PredictionLogEntry(
                predictionID: ladder.id,
                loggedAt: ladder.generatedAt,
                kind: .frontier,
                optionID: nil,
                payloadJSON: payloadString
            )
        }
        let headerPayload: [String: String] = [
            "destinationTitle": ladder.destinationTitle,
            "headline": ladder.headline ?? "",
            "nextCliffAt": ladder.nextCliffAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "rowCount": String(ladder.rows.count),
            "origin": origin ?? ""
        ]
        let headerEntry = PredictionLogEntry(
            predictionID: ladder.id,
            loggedAt: ladder.generatedAt,
            kind: .recommendation,
            payloadJSON: payloadJSON(headerPayload)
        )
        let episode = JourneyEpisodeLog(
            sessionID: sessionID,
            startedAt: ladder.generatedAt,
            closedAt: ladder.generatedAt,
            entries: [headerEntry] + entries
        )
        appendEpisode(episode)
    }

    func readAllEpisodes() -> [JourneyEpisodeLog] {
        guard let data = try? Data(contentsOf: activeURL) else { return [] }
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(JourneyEpisodeLog.self, from: Data($0)) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: activeURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: activeURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: activeURL, to: rotatedURL)
    }

    private func payloadJSON(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static var defaultDirectory: URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Calibration", isDirectory: true)
    }
}
