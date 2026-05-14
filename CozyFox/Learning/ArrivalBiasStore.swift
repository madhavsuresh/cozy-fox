import Foundation
import Observation
import TransitCache
import TransitModels

/// Persistent store of Welford-style running statistics keyed by
/// `BiasCellKey`. Each cell estimates "predicted-vs-observed arrival
/// seconds" for one stratification bucket (line × stop × direction × hour ×
/// weekday-class × season). Phase 0 stores them with no consumer — later
/// phases will use the means and variances to bias the dashboard's ETA
/// display and to surface confidence-aware journey nudges.
///
/// Modeled on `WalkingDistanceStore`: `@Observable`, main-actor, lazy disk
/// hydration with the same race-guard pattern.
@MainActor
@Observable
final class ArrivalBiasStore {
    private(set) var cells: [BiasCellKey: BiasCell] = [:]

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadTask: Task<[StoredCell], Never>?

    @ObservationIgnored
    private var hasLoadedFromDisk = false

    @ObservationIgnored
    private var shouldDiscardOnHydrate = false

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    // MARK: Hydration

    func hydrateFromDiskIfNeeded() async {
        guard !hasLoadedFromDisk else { return }
        let task: Task<[StoredCell], Never>
        if let existing = loadTask {
            task = existing
        } else {
            let url = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadPersistedCells(from: url)
            }
            loadTask = task
        }
        let loaded = await task.value
        guard !hasLoadedFromDisk else { return }
        loadTask = nil
        hasLoadedFromDisk = true
        guard !shouldDiscardOnHydrate else { return }
        for entry in loaded {
            // Merge — never overwrite an in-memory cell that's already been
            // updated by an early `recordSample` racing with hydration.
            if cells[entry.key] == nil {
                cells[entry.key] = entry.cell
            }
        }
    }

    // MARK: Sample recording

    func recordSample(key: BiasCellKey, deltaSeconds: Double, at when: Date) {
        var cell = cells[key] ?? BiasCell()
        cell.recordSample(deltaSeconds, at: when)
        cells[key] = cell
        persistDebounced()
    }

    /// Test-only accessor.
    func snapshot(key: BiasCellKey) -> BiasCell? {
        cells[key]
    }

    /// Apply exponential decay to every cell. Phase 0 does not call this
    /// during runtime; the maintenance task runs it once a night. Cells
    /// whose effective count drops to zero are removed.
    func decay(halfLifeDays: Double, now: Date) {
        guard halfLifeDays > 0 else { return }
        var updated: [BiasCellKey: BiasCell] = [:]
        updated.reserveCapacity(cells.count)
        for (key, var cell) in cells {
            cell.decay(halfLifeDays: halfLifeDays, now: now)
            if cell.count > 0 {
                updated[key] = cell
            }
        }
        cells = updated
        persistDebounced()
    }

    // MARK: Reset

    func clearAll() {
        loadTask?.cancel()
        loadTask = nil
        hasLoadedFromDisk = true
        shouldDiscardOnHydrate = true
        cells.removeAll()
        persistDebounced()
    }

    // MARK: Persistence

    /// Encoded payload — JSON dictionaries don't natively support struct
    /// keys, so we flatten `(key, cell)` pairs to an array.
    struct StoredCell: Codable, Sendable {
        let key: BiasCellKey
        let cell: BiasCell
    }

    private struct Persisted: Codable, Sendable {
        let version: Int
        let cells: [StoredCell]
    }

    nonisolated static func loadPersistedCells(from fileURL: URL) -> [StoredCell] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Persisted.self, from: data),
              decoded.version == 1 else {
            return []
        }
        return decoded.cells
    }

    private static func defaultFileURL() -> URL {
        let container = AppGroup.containerURL
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
            ?? FileManager.default.temporaryDirectory
        let appSupport = container.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("ArrivalBiasStore.v1.json")
    }

    func persistDebounced() {
        persistTask?.cancel()
        let stored = Persisted(
            version: 1,
            cells: cells.map { StoredCell(key: $0.key, cell: $0.value) }
        )
        let url = fileURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(stored) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func persistNow() async {
        persistTask?.cancel()
        let stored = Persisted(
            version: 1,
            cells: cells.map { StoredCell(key: $0.key, cell: $0.value) }
        )
        let url = fileURL
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(stored) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
