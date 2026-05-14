import Foundation
import Observation
import TransitCache
import TransitModels

/// Persistent on-device store of `WeeklySummary` rows plus a single
/// EWMA-folded `LongTermProfile`. Phase 0 ships with no readers — the
/// `Snapshot` accessor and the `fold` method are present so subsequent
/// phases (Markov anchor predictor, journey Live Activity) can land without
/// schema changes.
///
/// Modeled on `WalkingDistanceStore`: lives on the main actor, is
/// `@Observable` so SwiftUI debug surfaces (e.g. a future "Reset learning"
/// button that wants to show the entry count) can subscribe, and hydrates
/// from disk lazily on first call to `hydrateFromDiskIfNeeded()`.
@MainActor
@Observable
final class MobilitySummaryStore {
    private(set) var weeklySummaries: [WeeklySummary] = []
    private(set) var longTermProfile: LongTermProfile = .empty

    @ObservationIgnored
    private var persistTask: Task<Void, Never>?

    @ObservationIgnored
    private var loadTask: Task<Persisted, Never>?

    @ObservationIgnored
    private var hasLoadedFromDisk = false

    @ObservationIgnored
    private var shouldDiscardOnHydrate = false

    private let fileURL: URL
    private let calendar: Calendar

    static let maxWeeklySummaries = 104

    init(
        fileURL: URL? = nil,
        calendar: Calendar = .current
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.calendar = calendar
    }

    // MARK: Hydration

    func hydrateFromDiskIfNeeded() async {
        guard !hasLoadedFromDisk else { return }
        let task: Task<Persisted, Never>
        if let existing = loadTask {
            task = existing
        } else {
            let url = fileURL
            task = Task.detached(priority: .utility) {
                Self.loadPersisted(from: url)
            }
            loadTask = task
        }

        let loaded = await task.value
        guard !hasLoadedFromDisk else { return }
        loadTask = nil
        hasLoadedFromDisk = true
        guard !shouldDiscardOnHydrate else { return }
        if weeklySummaries.isEmpty {
            weeklySummaries = loaded.weeklySummaries
        }
        if longTermProfile == .empty {
            longTermProfile = loaded.longTermProfile
        }
    }

    // MARK: Snapshot

    struct Snapshot: Sendable {
        let weeklySummaries: [WeeklySummary]
        let longTermProfile: LongTermProfile
    }

    /// Cheap, immutable snapshot for off-main consumers. Returns a copy so
    /// the caller can iterate without holding the main actor.
    func snapshot() -> Snapshot {
        Snapshot(
            weeklySummaries: weeklySummaries,
            longTermProfile: longTermProfile
        )
    }

    // MARK: Fold

    /// The result of folding observations into the store. Phase 0 callers
    /// (`PredictionMaintenanceTask`) replace the profile with `mutatedProfile`.
    struct FoldResult: Sendable {
        let mutatedProfile: MobilityProfile
        let foldedObservationCount: Int
        let foldedRouteObservationCount: Int
    }

    /// Fold observations older than 14 days into the current week's
    /// `WeeklySummary`, drop them from the supplied `MobilityProfile`, and
    /// update `LongTermProfile` via EWMA. Returns the trimmed profile so the
    /// caller can persist it.
    @discardableResult
    func fold(profile: MobilityProfile, now: Date = .now) -> FoldResult {
        let cutoff = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let foldableObservations = profile.observations.filter { $0.recordedAt < cutoff }
        let foldableRoutes = profile.routeObservations.filter { $0.recordedAt < cutoff }

        if foldableObservations.isEmpty && foldableRoutes.isEmpty {
            return FoldResult(
                mutatedProfile: profile,
                foldedObservationCount: 0,
                foldedRouteObservationCount: 0
            )
        }

        // Group foldable rows by ISO week start. The bulk of the fold work
        // happens inside this loop; downstream phases will read these
        // histograms hour-by-hour.
        var grouped: [Date: WeekAggregate] = [:]
        for obs in foldableObservations {
            let weekStart = startOfWeek(for: obs.recordedAt)
            var agg = grouped[weekStart] ?? WeekAggregate()
            let hourOfWeek = HourOfWeek.index(weekday: obs.weekday, hour: obs.hour)
            if let motion = obs.motion {
                agg.motion[motion, default: 0] += 1
            }
            agg.observationsByHour[hourOfWeek, default: 0] += 1
            grouped[weekStart] = agg
        }
        for r in foldableRoutes {
            let weekStart = startOfWeek(for: r.recordedAt)
            var agg = grouped[weekStart] ?? WeekAggregate()
            let hourOfWeek = HourOfWeek.index(weekday: r.weekday, hour: r.hour)
            let anchor = primaryAnchor(for: r)
            agg.anchorByHour[hourOfWeek, default: [:]][anchor, default: 0] += 1
            agg.modeByHour[hourOfWeek, default: ModeWeights.zero] =
                addMode(agg.modeByHour[hourOfWeek] ?? .zero, for: r)
            if let origin = r.origin {
                let originAnchor = AnchorID.bucketed(
                    latitude: origin.latitude,
                    longitude: origin.longitude
                )
                let destinationAnchor = r.destination.map {
                    AnchorID.bucketed(latitude: $0.latitude, longitude: $0.longitude)
                } ?? anchor
                let key = CorridorKey(origin: originAnchor, destination: destinationAnchor)
                var entry = agg.corridors[key] ?? CorridorAccumulator(
                    origin: originAnchor,
                    destination: destinationAnchor
                )
                entry.frequency += 1
                entry.dominantMode = entry.dominantMode ?? modeFor(r)
                agg.corridors[key] = entry
            }
            if let motion = r.motion {
                agg.motion[motion, default: 0] += 1
            }
            grouped[weekStart] = agg
        }

        // Merge each week's aggregate into either an existing summary or a
        // freshly-created one, then push the latest into the long-term
        // profile.
        for (weekStart, agg) in grouped {
            let mergedSummary = merge(weekStart: weekStart, aggregate: agg)
            longTermProfile.fold(mergedSummary)
        }

        // Cap retention.
        weeklySummaries.sort { $0.weekStart < $1.weekStart }
        if weeklySummaries.count > Self.maxWeeklySummaries {
            weeklySummaries.removeFirst(weeklySummaries.count - Self.maxWeeklySummaries)
        }

        // Trim the source profile.
        var mutated = profile
        mutated.observations.removeAll { $0.recordedAt < cutoff }
        mutated.routeObservations.removeAll { $0.recordedAt < cutoff }
        mutated.updatedAt = now

        persistDebounced()

        return FoldResult(
            mutatedProfile: mutated,
            foldedObservationCount: foldableObservations.count,
            foldedRouteObservationCount: foldableRoutes.count
        )
    }

    // MARK: Mutation helpers

    private func merge(weekStart: Date, aggregate: WeekAggregate) -> WeeklySummary {
        let existingIndex = weeklySummaries.firstIndex { $0.weekStart == weekStart }
        var summary = existingIndex.map { weeklySummaries[$0] }
            ?? WeeklySummary(weekStart: weekStart)

        for (hour, byAnchor) in aggregate.anchorByHour {
            var slot = summary.hourlyAnchorHistogram[hour] ?? [:]
            for (anchor, count) in byAnchor {
                slot[anchor, default: 0] += count
            }
            summary.hourlyAnchorHistogram[hour] = slot
        }
        for (hour, mode) in aggregate.modeByHour {
            let prev = summary.hourlyModeProbabilities[hour] ?? .zero
            summary.hourlyModeProbabilities[hour] = prev + mode
        }
        for (motion, count) in aggregate.motion {
            summary.motionDistribution[motion, default: 0] += count
        }

        // Re-rank corridors. Merge the aggregate into anything already
        // present, then sort descending by frequency and cap.
        var corridorMap: [CorridorKey: CorridorSummary] = [:]
        for c in summary.topCorridors {
            corridorMap[CorridorKey(origin: c.origin, destination: c.destination)] = c
        }
        for (key, acc) in aggregate.corridors {
            if let existing = corridorMap[key] {
                corridorMap[key] = CorridorSummary(
                    origin: existing.origin,
                    destination: existing.destination,
                    frequency: existing.frequency + acc.frequency,
                    dominantMode: existing.dominantMode ?? acc.dominantMode
                )
            } else {
                corridorMap[key] = CorridorSummary(
                    origin: acc.origin,
                    destination: acc.destination,
                    frequency: acc.frequency,
                    dominantMode: acc.dominantMode
                )
            }
        }
        summary.topCorridors = corridorMap.values
            .sorted { $0.frequency > $1.frequency }
            .prefix(WeeklySummary.maxCorridors)
            .map { $0 }

        if let idx = existingIndex {
            weeklySummaries[idx] = summary
        } else {
            weeklySummaries.append(summary)
        }
        return summary
    }

    private func primaryAnchor(for r: MobilityProfile.RouteObservation) -> AnchorID {
        if let stationId = r.stationId {
            return .lStation(stationId: stationId)
        }
        if let metraStation = r.metraStationId {
            return .metraStation(stationId: metraStation)
        }
        // Bus observations don't carry a stop id on RouteObservation today,
        // so they fold by destination/origin coordinates rather than into a
        // .busStop anchor. Phase 1 will revisit once boarding events emit
        // stop ids directly.
        if let destination = r.destination {
            return AnchorID.bucketed(latitude: destination.latitude, longitude: destination.longitude)
        }
        if let origin = r.origin {
            return AnchorID.bucketed(latitude: origin.latitude, longitude: origin.longitude)
        }
        return r.direction == .toHome ? .home : .work
    }

    private func addMode(_ prev: ModeWeights, for r: MobilityProfile.RouteObservation) -> ModeWeights {
        var next = prev
        if r.line != nil { next.train += 1 }
        if r.busRoute != nil { next.bus += 1 }
        if r.metraRoute != nil { next.metra += 1 }
        return next
    }

    private func modeFor(_ r: MobilityProfile.RouteObservation) -> TransitMode? {
        if r.line != nil { return .train }
        if r.busRoute != nil { return .bus }
        if r.metraRoute != nil { return .metra }
        return nil
    }

    /// ISO-style Monday-anchored start of week, at local 00:00. We don't use
    /// `Calendar.dateInterval(of: .weekOfYear)` directly because that obeys
    /// `firstWeekday` which is locale-specific; transit schedules are
    /// effectively Monday-anchored.
    private func startOfWeek(for date: Date) -> Date {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        cal.minimumDaysInFirstWeek = 4 // ISO-8601
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return cal.date(from: comps) ?? date
    }

    // MARK: Reset

    func clearAll() {
        loadTask?.cancel()
        loadTask = nil
        hasLoadedFromDisk = true
        shouldDiscardOnHydrate = true
        weeklySummaries.removeAll()
        longTermProfile = .empty
        persistDebounced()
    }

    // MARK: Persistence

    struct Persisted: Codable, Sendable {
        let version: Int
        let weeklySummaries: [WeeklySummary]
        let longTermProfile: LongTermProfile
    }

    private static func defaultFileURL() -> URL {
        let container = AppGroup.containerURL
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
            ?? FileManager.default.temporaryDirectory
        // Application Support inside the App Group container — not the
        // caches directory, because learning data should not be evictable by
        // iOS when storage is tight.
        let appSupport = container.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("MobilitySummaryStore.v1.json")
    }

    nonisolated static func loadPersisted(from fileURL: URL) -> Persisted {
        let empty = Persisted(version: 1, weeklySummaries: [], longTermProfile: .empty)
        guard let data = try? Data(contentsOf: fileURL) else { return empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Persisted.self, from: data),
           decoded.version == 1 {
            return decoded
        }
        return empty
    }

    func persistDebounced() {
        persistTask?.cancel()
        let snapshot = Persisted(
            version: 1,
            weeklySummaries: weeklySummaries,
            longTermProfile: longTermProfile
        )
        let url = fileURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// For tests / maintenance: write synchronously, bypassing the debounce.
    func persistNow() async {
        persistTask?.cancel()
        let snapshot = Persisted(
            version: 1,
            weeklySummaries: weeklySummaries,
            longTermProfile: longTermProfile
        )
        let url = fileURL
        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}

// MARK: - Fold scratch

/// Mutable per-week accumulator used during a single `fold` call. Lives
/// only on the main actor so it doesn't need to be `Sendable`.
private struct WeekAggregate {
    var observationsByHour: [Int: Int] = [:]
    var anchorByHour: [Int: [AnchorID: Double]] = [:]
    var modeByHour: [Int: ModeWeights] = [:]
    var motion: [MotionContext: Double] = [:]
    var corridors: [CorridorKey: CorridorAccumulator] = [:]
}

private struct CorridorKey: Hashable {
    let origin: AnchorID
    let destination: AnchorID
}

private struct CorridorAccumulator {
    let origin: AnchorID
    let destination: AnchorID
    var frequency: Double = 0
    var dominantMode: TransitMode? = nil
}
