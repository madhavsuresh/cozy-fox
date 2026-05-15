import Foundation
import TransitModels

/// Produces an `ArrivalConfidenceMark` for a single arrival from the
/// signals the app already has on hand — the agency-reported arrival
/// flags + the per-cell bias statistics learned by `ArrivalGrader`.
///
/// Nonverbal by design: the score is just a `[0, 1]` strength and the
/// tone is one of `.strong | .normal | .weak`. Surfaces render this
/// as dot weight / opacity on the Live Activity strip without changing
/// any user-facing copy.
///
/// Pure / `Sendable`. The Live Activity coordinator snapshots the
/// bias-cell map on the main actor and hands it here off-actor.
public enum ArrivalConfidenceMarker {
    public static let strongThreshold: Double = 0.72
    public static let normalThreshold: Double = 0.45

    public static func mark(
        for arrival: Arrival,
        biasCell: BiasCell?,
        ghostScore: Double? = nil
    ) -> ArrivalConfidenceMark {
        var score = baselineScore
        if arrival.isFault { score -= 0.4 }
        if arrival.isScheduled { score -= 0.15 }
        if arrival.isDelayed { score -= 0.05 }
        if let ghostScore { score -= max(0, min(1, ghostScore)) * 0.35 }
        score += biasReliabilityBoost(biasCell)
        return mark(arrivalID: arrival.id, arrivalAt: arrival.arrivalAt, rawScore: score)
    }

    public static func mark(
        for prediction: BusPrediction,
        biasCell: BiasCell?
    ) -> ArrivalConfidenceMark {
        var score = baselineScore
        if prediction.isDelayed { score -= 0.06 }
        // `isApproaching` is a near-stop signal; the dot strip already
        // surfaces "soon" via position, so we lean slightly negative
        // because the user has less margin to act on a confidence
        // dot for an imminent prediction.
        if prediction.isApproaching { score -= 0.04 }
        score += biasReliabilityBoost(biasCell)
        return mark(arrivalID: prediction.id, arrivalAt: prediction.arrivalAt, rawScore: score)
    }

    public static func mark(
        for prediction: MetraPrediction
    ) -> ArrivalConfidenceMark {
        // Metra arrivals don't currently flow through `ArrivalGrader`,
        // so we score purely from the prediction's own flags.
        var score = baselineScore
        if prediction.isCanceled { score -= 0.5 }
        if prediction.isScheduled { score -= 0.12 }
        if prediction.isDelayed { score -= 0.05 }
        return mark(arrivalID: prediction.id, arrivalAt: prediction.arrivalAt, rawScore: score)
    }

    // MARK: - Implementation

    /// The starting confidence for an unflagged live arrival with no
    /// learning history. Maps to `.normal` after clamping.
    private static let baselineScore: Double = 0.65

    private static func biasReliabilityBoost(_ cell: BiasCell?) -> Double {
        guard let cell else { return 0 }
        var boost: Double = 0
        // High historical stddev → less confidence the live prediction
        // tracks reality. Mirrors the `RouteOptionScorer`'s uncertainty
        // penalty so the LA and dashboard agree on which arrivals are
        // shaky.
        if let stddev = cell.standardDeviation {
            if stddev >= 5 * 60 { boost -= 0.18 }
            else if stddev >= 3 * 60 { boost -= 0.08 }
            else if stddev >= 2 * 60 { boost -= 0.04 }
        }
        // Many samples + small bias mean → high reliability.
        if cell.count >= 12, abs(cell.mean) < 60 {
            boost += 0.18
        }
        return boost
    }

    private static func mark(
        arrivalID: String,
        arrivalAt: Date,
        rawScore: Double
    ) -> ArrivalConfidenceMark {
        let clamped = max(0, min(1, rawScore))
        let tone: ArrivalConfidenceMark.Tone
        if clamped >= strongThreshold {
            tone = .strong
        } else if clamped >= normalThreshold {
            tone = .normal
        } else {
            tone = .weak
        }
        return ArrivalConfidenceMark(
            id: arrivalID,
            arrivalAt: arrivalAt,
            score: clamped,
            tone: tone
        )
    }
}
