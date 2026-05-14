import Foundation
import TransitModels

/// Pure, side-effect-free predictor of the user's likely *next* anchor given
/// where they are now and what hour of the week it is. Reads only from a
/// `LongTermProfile` snapshot — no I/O, no actor — so callers can run it off
/// the main actor and pass the result as a hint to higher-level pickers.
///
/// The algorithm is intentionally simple and predictable:
///   1. If hourly stratified corridors exist for the current hour, filter
///      them to those whose origin matches `currentAnchor` and use their
///      EWMA-smoothed `frequency` as the candidate score.
///   2. Otherwise fall back to the unstratified `topCorridors` filtered the
///      same way.
///   3. Independently, multiply each candidate by the *future-hour* marginal
///      `hourlyAnchorHistogram[(hourOfWeek + lookaheadHours) % 168]` weight
///      as a soft prior. With `currentAnchor == nil`, this marginal IS the
///      predictor.
///   4. Pick the top `limit` via bounded one-pass insertion (same shape as
///      `NearestStationResolver.boundedNearest`).
///   5. Below a confidence threshold (`minConfidence = 1.0`) return `[]` so
///      callers can treat the result as "no hint" without inspecting scores.
public struct NextAnchorPredictor: Sendable {
    public struct Prediction: Sendable, Hashable {
        public let anchor: AnchorID
        public let probability: Double

        public init(anchor: AnchorID, probability: Double) {
            self.anchor = anchor
            self.probability = probability
        }
    }

    /// Total candidate weight required before we'll return any predictions.
    /// Below this, the signal is too noisy to be useful as a hint — the
    /// autopinner's own scoring is a better source of truth.
    public static let minConfidence: Double = 1.0

    public init() {}

    /// Returns up to `limit` ranked next-anchor predictions for the given
    /// (currentAnchor, hourOfWeek) context against the long-term profile.
    /// Returns an empty array when the profile lacks enough signal to make a
    /// confident prediction — callers should treat that as "no hint."
    public func predict(
        profile: LongTermProfile,
        currentAnchor: AnchorID?,
        hourOfWeek: Int,
        motion: MotionContext? = nil,
        lookaheadHours: Int = 1,
        limit: Int = 3
    ) -> [Prediction] {
        guard limit > 0 else { return [] }
        let normalizedHour = ((hourOfWeek % 168) + 168) % 168
        let futureHour = ((normalizedHour + lookaheadHours) % 168 + 168) % 168

        // Step 1/2: assemble unnormalized candidate scores from corridors.
        var candidateScores: [AnchorID: Double] = [:]
        if let currentAnchor {
            let stratifiedCorridors = profile.hourlyTopCorridors[normalizedHour] ?? []
            let filtered = stratifiedCorridors.filter { $0.origin == currentAnchor }
            if !filtered.isEmpty {
                for c in filtered {
                    candidateScores[c.destination, default: 0] += c.frequency
                }
            } else {
                // Fall back to unstratified corridors for the same origin.
                for c in profile.topCorridors where c.origin == currentAnchor {
                    candidateScores[c.destination, default: 0] += c.frequency
                }
            }
        }

        // Step 3: soft marginal prior over the future hour. Either folds into
        // existing candidates or — when we have none — becomes the predictor.
        let futureMarginal = profile.hourlyAnchorHistogram[futureHour] ?? [:]
        if candidateScores.isEmpty {
            for (anchor, weight) in futureMarginal where weight > 0 {
                // Exclude the user's current anchor — "you're already here" is
                // not a useful next-step hint.
                if let currentAnchor, anchor == currentAnchor { continue }
                candidateScores[anchor] = weight
            }
        } else {
            // Use 1 + marginal so corridors with no matching future signal
            // aren't zeroed out, but ones that do match get a real bump.
            for (anchor, score) in candidateScores {
                let marginal = futureMarginal[anchor] ?? 0
                candidateScores[anchor] = score * (1 + marginal)
            }
        }

        // Suppress motion-incompatible candidates: a stationary user is
        // unlikely to be about to arrive somewhere new. We keep this very
        // soft — drop scores by half rather than filter outright, so the
        // hint can still tip a tie if the user is sitting at a known anchor.
        if motion == .stationary {
            for (anchor, score) in candidateScores {
                candidateScores[anchor] = score * 0.5
            }
        }

        // Step 5: confidence gate before normalization.
        let totalWeight = candidateScores.values.reduce(0, +)
        guard totalWeight >= Self.minConfidence else { return [] }

        // Step 4: bounded one-pass top-K. Same shape as
        // `NearestStationResolver.boundedNearest` — we keep `best` sorted
        // descending by score, insert in order, and trim when over `limit`.
        var best: [(anchor: AnchorID, score: Double)] = []
        best.reserveCapacity(limit)
        for (anchor, score) in candidateScores where score > 0 {
            let entry = (anchor: anchor, score: score)
            let index = best.firstIndex { entry.score > $0.score } ?? best.endIndex
            if index < best.endIndex {
                best.insert(entry, at: index)
            } else if best.count < limit {
                best.append(entry)
            }
            if best.count > limit {
                best.removeLast()
            }
        }

        guard !best.isEmpty else { return [] }
        return best.map { Prediction(anchor: $0.anchor, probability: $0.score / totalWeight) }
    }
}
