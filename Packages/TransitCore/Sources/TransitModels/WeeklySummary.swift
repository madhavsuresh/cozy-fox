import Foundation

// MARK: - WeeklySummary

/// Aggregated mobility signal for a single ISO week. Phase 0 folds
/// observations and route observations into this shape; later phases will
/// read from it for next-anchor prediction. Coordinates are bucketed via
/// `AnchorID` so this artifact never holds a raw GPS trace.
public struct WeeklySummary: Codable, Sendable, Hashable {
    /// Monday 00:00 local. We don't carry the time zone separately — the
    /// `Date` itself fixes the instant, and the calendar that rolled the
    /// summary is responsible for converting back to local when needed.
    public let weekStart: Date

    /// `hourOfWeek` (0...167) → anchor-weight vector. Weights, not
    /// probabilities, so EWMA folding doesn't need renormalization.
    public var hourlyAnchorHistogram: [Int: [AnchorID: Double]]

    /// `hourOfWeek` (0...167) → mode-share vector for the same window.
    public var hourlyModeProbabilities: [Int: ModeWeights]

    /// Top corridors by frequency, capped at `maxCorridors`.
    public var topCorridors: [CorridorSummary]

    /// `hourOfWeek` (0...167) → top corridors observed in that hour bucket.
    /// Bounded per-hour just like `topCorridors`. Defaults to empty for files
    /// written by Phase 0 — `decodeIfPresent` handles the migration.
    public var hourlyTopCorridors: [Int: [CorridorSummary]]

    /// Distribution over coarse motion contexts (Core Motion classes). Used
    /// later by the journey Live Activity to suppress "you're moving" cues
    /// for users who are stationary almost all week.
    public var motionDistribution: [MotionContext: Double]

    /// Anomaly autoencoder's mean reconstruction loss for this week. Stays
    /// `nil` in Phase 0 — the model is not implemented yet, but persisting a
    /// field reserves the schema so we don't need a version bump later.
    public var autoencoderReconstructionMean: Double?

    public static let maxCorridors = 8

    public init(
        weekStart: Date,
        hourlyAnchorHistogram: [Int: [AnchorID: Double]] = [:],
        hourlyModeProbabilities: [Int: ModeWeights] = [:],
        topCorridors: [CorridorSummary] = [],
        hourlyTopCorridors: [Int: [CorridorSummary]] = [:],
        motionDistribution: [MotionContext: Double] = [:],
        autoencoderReconstructionMean: Double? = nil
    ) {
        self.weekStart = weekStart
        self.hourlyAnchorHistogram = hourlyAnchorHistogram
        self.hourlyModeProbabilities = hourlyModeProbabilities
        self.topCorridors = topCorridors
        self.hourlyTopCorridors = hourlyTopCorridors
        self.motionDistribution = motionDistribution
        self.autoencoderReconstructionMean = autoencoderReconstructionMean
    }

    // MARK: Codable (backward-compatible with Phase 0 files)

    private enum CodingKeys: String, CodingKey {
        case weekStart
        case hourlyAnchorHistogram
        case hourlyModeProbabilities
        case topCorridors
        case hourlyTopCorridors
        case motionDistribution
        case autoencoderReconstructionMean
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.weekStart = try c.decode(Date.self, forKey: .weekStart)
        self.hourlyAnchorHistogram = try c.decodeIfPresent(
            [Int: [AnchorID: Double]].self,
            forKey: .hourlyAnchorHistogram
        ) ?? [:]
        self.hourlyModeProbabilities = try c.decodeIfPresent(
            [Int: ModeWeights].self,
            forKey: .hourlyModeProbabilities
        ) ?? [:]
        self.topCorridors = try c.decodeIfPresent(
            [CorridorSummary].self,
            forKey: .topCorridors
        ) ?? []
        // Phase 0 files omit `hourlyTopCorridors` — default to empty so they
        // hydrate without a version bump.
        self.hourlyTopCorridors = try c.decodeIfPresent(
            [Int: [CorridorSummary]].self,
            forKey: .hourlyTopCorridors
        ) ?? [:]
        self.motionDistribution = try c.decodeIfPresent(
            [MotionContext: Double].self,
            forKey: .motionDistribution
        ) ?? [:]
        self.autoencoderReconstructionMean = try c.decodeIfPresent(
            Double.self,
            forKey: .autoencoderReconstructionMean
        )
    }
}

// MARK: - LongTermProfile

/// Same shape as `WeeklySummary` but updated each week via EWMA so it
/// captures longer-horizon behavior without retaining every week verbatim.
/// `weekStart` here means the most recent week folded into the average, not
/// any anchor week — Phase 0 only writes it; downstream consumers will read.
public struct LongTermProfile: Codable, Sendable, Hashable {
    public var weekStart: Date?
    public var hourlyAnchorHistogram: [Int: [AnchorID: Double]]
    public var hourlyModeProbabilities: [Int: ModeWeights]
    public var topCorridors: [CorridorSummary]
    /// `hourOfWeek` (0...167) → top corridors observed in that hour bucket
    /// after EWMA smoothing. Capped per hour at `WeeklySummary.maxCorridors`.
    /// Defaults to empty for files written by Phase 0.
    public var hourlyTopCorridors: [Int: [CorridorSummary]]
    public var motionDistribution: [MotionContext: Double]
    public var autoencoderReconstructionMean: Double?

    /// Default smoothing constant. Picked at 0.3 because we expect 6+ weeks
    /// of usable signal before downstream code reads from this, so we want
    /// recent weeks to dominate but not erase older patterns.
    public static let defaultAlpha: Double = 0.3

    public init(
        weekStart: Date? = nil,
        hourlyAnchorHistogram: [Int: [AnchorID: Double]] = [:],
        hourlyModeProbabilities: [Int: ModeWeights] = [:],
        topCorridors: [CorridorSummary] = [],
        hourlyTopCorridors: [Int: [CorridorSummary]] = [:],
        motionDistribution: [MotionContext: Double] = [:],
        autoencoderReconstructionMean: Double? = nil
    ) {
        self.weekStart = weekStart
        self.hourlyAnchorHistogram = hourlyAnchorHistogram
        self.hourlyModeProbabilities = hourlyModeProbabilities
        self.topCorridors = topCorridors
        self.hourlyTopCorridors = hourlyTopCorridors
        self.motionDistribution = motionDistribution
        self.autoencoderReconstructionMean = autoencoderReconstructionMean
    }

    public static let empty = LongTermProfile()

    // MARK: Codable (backward-compatible with Phase 0 files)

    private enum CodingKeys: String, CodingKey {
        case weekStart
        case hourlyAnchorHistogram
        case hourlyModeProbabilities
        case topCorridors
        case hourlyTopCorridors
        case motionDistribution
        case autoencoderReconstructionMean
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.weekStart = try c.decodeIfPresent(Date.self, forKey: .weekStart)
        self.hourlyAnchorHistogram = try c.decodeIfPresent(
            [Int: [AnchorID: Double]].self,
            forKey: .hourlyAnchorHistogram
        ) ?? [:]
        self.hourlyModeProbabilities = try c.decodeIfPresent(
            [Int: ModeWeights].self,
            forKey: .hourlyModeProbabilities
        ) ?? [:]
        self.topCorridors = try c.decodeIfPresent(
            [CorridorSummary].self,
            forKey: .topCorridors
        ) ?? []
        // Phase 0 files omit `hourlyTopCorridors` — default to empty.
        self.hourlyTopCorridors = try c.decodeIfPresent(
            [Int: [CorridorSummary]].self,
            forKey: .hourlyTopCorridors
        ) ?? [:]
        self.motionDistribution = try c.decodeIfPresent(
            [MotionContext: Double].self,
            forKey: .motionDistribution
        ) ?? [:]
        self.autoencoderReconstructionMean = try c.decodeIfPresent(
            Double.self,
            forKey: .autoencoderReconstructionMean
        )
    }

    // MARK: EWMA fold

    /// Fold a freshly-computed `WeeklySummary` into the long-term profile.
    /// Each scalar field becomes `(1-α) * old + α * new`. Anchor histograms
    /// and mode vectors are merged key-by-key with the same smoothing so a
    /// previously-frequent anchor doesn't vanish the first week it isn't
    /// visited.
    public mutating func fold(_ week: WeeklySummary, alpha: Double = LongTermProfile.defaultAlpha) {
        let a = max(0, min(1, alpha))
        let oneMinus = 1 - a

        // Per-hour anchor histogram.
        var newAnchor: [Int: [AnchorID: Double]] = [:]
        let allHours = Set(hourlyAnchorHistogram.keys).union(week.hourlyAnchorHistogram.keys)
        for hour in allHours {
            let old = hourlyAnchorHistogram[hour] ?? [:]
            let new = week.hourlyAnchorHistogram[hour] ?? [:]
            var merged: [AnchorID: Double] = [:]
            for (k, v) in old { merged[k] = v * oneMinus }
            for (k, v) in new { merged[k, default: 0] += v * a }
            newAnchor[hour] = merged
        }
        hourlyAnchorHistogram = newAnchor

        // Per-hour mode weights.
        var newMode: [Int: ModeWeights] = [:]
        let allModeHours = Set(hourlyModeProbabilities.keys).union(week.hourlyModeProbabilities.keys)
        for hour in allModeHours {
            let old = hourlyModeProbabilities[hour] ?? .zero
            let new = week.hourlyModeProbabilities[hour] ?? .zero
            newMode[hour] = old * oneMinus + new * a
        }
        hourlyModeProbabilities = newMode

        // Motion distribution.
        var newMotion: [MotionContext: Double] = [:]
        let allMotion = Set(motionDistribution.keys).union(week.motionDistribution.keys)
        for k in allMotion {
            let old = motionDistribution[k] ?? 0
            let new = week.motionDistribution[k] ?? 0
            newMotion[k] = old * oneMinus + new * a
        }
        motionDistribution = newMotion

        // Top corridors: union both, smooth frequencies, keep top N.
        topCorridors = foldCorridors(
            old: topCorridors,
            new: week.topCorridors,
            alpha: a
        )

        // Per-hour top corridors: same fold rule, keyed by hourOfWeek so
        // downstream predictors can pivot on (currentAnchor, hourOfWeek).
        var newHourlyCorridors: [Int: [CorridorSummary]] = [:]
        let allCorridorHours = Set(hourlyTopCorridors.keys).union(week.hourlyTopCorridors.keys)
        for hour in allCorridorHours {
            let oldList = hourlyTopCorridors[hour] ?? []
            let newList = week.hourlyTopCorridors[hour] ?? []
            let folded = foldCorridors(old: oldList, new: newList, alpha: a)
            if !folded.isEmpty {
                newHourlyCorridors[hour] = folded
            }
        }
        hourlyTopCorridors = newHourlyCorridors

        // Reconstruction mean only updates when the new week has one.
        if let newRecon = week.autoencoderReconstructionMean {
            if let prior = autoencoderReconstructionMean {
                autoencoderReconstructionMean = prior * oneMinus + newRecon * a
            } else {
                autoencoderReconstructionMean = newRecon
            }
        }

        weekStart = week.weekStart
    }

    private struct CorridorKey: Hashable {
        let origin: AnchorID
        let destination: AnchorID
    }

    /// EWMA-fold one list of corridors into another, capped at
    /// `WeeklySummary.maxCorridors`. Extracted so the unstratified
    /// `topCorridors` fold and the per-hour `hourlyTopCorridors` fold share
    /// the same semantics — a newly-seen corridor enters with weight `α`, an
    /// existing one decays by `(1-α)` then absorbs `α * new.frequency`.
    private func foldCorridors(
        old: [CorridorSummary],
        new: [CorridorSummary],
        alpha a: Double
    ) -> [CorridorSummary] {
        let oneMinus = 1 - a
        var byKey: [CorridorKey: CorridorSummary] = [:]
        for c in old {
            byKey[CorridorKey(origin: c.origin, destination: c.destination)] =
                CorridorSummary(
                    origin: c.origin,
                    destination: c.destination,
                    frequency: c.frequency * oneMinus,
                    dominantMode: c.dominantMode
                )
        }
        for c in new {
            let key = CorridorKey(origin: c.origin, destination: c.destination)
            if let existing = byKey[key] {
                byKey[key] = CorridorSummary(
                    origin: existing.origin,
                    destination: existing.destination,
                    frequency: existing.frequency + c.frequency * a,
                    dominantMode: c.dominantMode ?? existing.dominantMode
                )
            } else {
                byKey[key] = CorridorSummary(
                    origin: c.origin,
                    destination: c.destination,
                    frequency: c.frequency * a,
                    dominantMode: c.dominantMode
                )
            }
        }
        return byKey.values
            .sorted { $0.frequency > $1.frequency }
            .prefix(WeeklySummary.maxCorridors)
            .map { $0 }
    }
}
