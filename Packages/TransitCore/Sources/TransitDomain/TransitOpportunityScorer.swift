import Foundation
import TransitModels

public struct TransitOpportunityScore: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable {
        case train
        case bus
        case metra
    }

    public enum Catchability: String, Sendable, Hashable {
        case past
        case tooSoon
        case tight
        case comfortable
        case distant
        case unknown
    }

    public let id: String
    public let mode: Mode
    public let arrivalAt: Date
    public let adjustedArrivalAt: Date
    public let score: Double
    public let catchability: Catchability
    public let confidence: Double

    public init(
        id: String,
        mode: Mode,
        arrivalAt: Date,
        adjustedArrivalAt: Date,
        score: Double,
        catchability: Catchability,
        confidence: Double
    ) {
        self.id = id
        self.mode = mode
        self.arrivalAt = arrivalAt
        self.adjustedArrivalAt = adjustedArrivalAt
        self.score = min(1, max(0, score))
        self.catchability = catchability
        self.confidence = min(1, max(0, confidence))
    }

    public var confidenceMark: ArrivalConfidenceMark {
        let tone: ArrivalConfidenceMark.Tone
        if score >= 0.72 {
            tone = .strong
        } else if score >= 0.45 {
            tone = .normal
        } else {
            tone = .weak
        }
        return ArrivalConfidenceMark(
            id: id,
            arrivalAt: arrivalAt,
            score: score,
            tone: tone
        )
    }
}

public struct TransitOpportunityScorer: Sendable {
    public init() {}

    public func scoreTrain(
        _ arrival: Arrival,
        access: PersonalAccessEstimate?,
        biasCell: BiasCell?,
        ghost: GhostTrainAssessment?,
        alerts: [ServiceAlert],
        now: Date = .now
    ) -> TransitOpportunityScore {
        let adjusted = adjustedArrival(arrival.arrivalAt, biasCell: biasCell)
        let catchability = catchability(
            adjustedArrivalAt: adjusted,
            access: access,
            now: now
        )
        var score = baseScore(catchability: catchability, access: access)
        if arrival.isScheduled { score -= 0.14 }
        if arrival.isFault { score -= 0.2 }
        if arrival.isDelayed { score -= 0.04 }
        if let ghost {
            score -= ghost.ghostScore * 0.45
        }
        score -= alertPenalty(alerts)
        score -= uncertaintyPenalty(biasCell)

        return TransitOpportunityScore(
            id: arrival.id,
            mode: .train,
            arrivalAt: arrival.arrivalAt,
            adjustedArrivalAt: adjusted,
            score: score,
            catchability: catchability,
            confidence: confidence(access: access, biasCell: biasCell, feedScore: 1 - (ghost?.ghostScore ?? 0))
        )
    }

    public func scoreBus(
        _ prediction: BusPrediction,
        access: PersonalAccessEstimate?,
        biasCell: BiasCell?,
        alerts: [ServiceAlert],
        now: Date = .now
    ) -> TransitOpportunityScore {
        let adjusted = adjustedArrival(prediction.arrivalAt, biasCell: biasCell)
        let catchability = catchability(
            adjustedArrivalAt: adjusted,
            access: access,
            now: now
        )
        var score = baseScore(catchability: catchability, access: access)
        if prediction.isDelayed { score -= 0.06 }
        if prediction.isApproaching { score -= 0.08 }
        score -= alertPenalty(alerts)
        score -= uncertaintyPenalty(biasCell)

        return TransitOpportunityScore(
            id: prediction.id,
            mode: .bus,
            arrivalAt: prediction.arrivalAt,
            adjustedArrivalAt: adjusted,
            score: score,
            catchability: catchability,
            confidence: confidence(access: access, biasCell: biasCell, feedScore: 0.85)
        )
    }

    public func scoreMetra(
        _ prediction: MetraPrediction,
        access: PersonalAccessEstimate?,
        alerts: [ServiceAlert],
        now: Date = .now
    ) -> TransitOpportunityScore {
        let catchability = catchability(
            adjustedArrivalAt: prediction.arrivalAt,
            access: access,
            now: now
        )
        var score = baseScore(catchability: catchability, access: access)
        if prediction.isCanceled { score = 0 }
        if prediction.isScheduled { score -= 0.12 }
        if prediction.isDelayed { score -= 0.04 }
        score -= alertPenalty(alerts)

        return TransitOpportunityScore(
            id: prediction.id,
            mode: .metra,
            arrivalAt: prediction.arrivalAt,
            adjustedArrivalAt: prediction.arrivalAt,
            score: score,
            catchability: catchability,
            confidence: min(1, (access?.confidence ?? 0.35) * 0.8 + (prediction.isScheduled ? 0.1 : 0.2))
        )
    }

    private func adjustedArrival(_ arrivalAt: Date, biasCell: BiasCell?) -> Date {
        guard let biasCell, biasCell.count >= 3 else { return arrivalAt }
        return arrivalAt.addingTimeInterval(biasCell.mean)
    }

    private func catchability(
        adjustedArrivalAt: Date,
        access: PersonalAccessEstimate?,
        now: Date
    ) -> TransitOpportunityScore.Catchability {
        let seconds = adjustedArrivalAt.timeIntervalSince(now)
        guard seconds > 0 else { return .past }
        guard let access else { return .unknown }

        let buffer: TimeInterval = 60
        if seconds < access.medianSeconds + buffer {
            return .tooSoon
        }
        if seconds < access.conservativeSeconds + buffer {
            return .tight
        }
        if seconds <= access.conservativeSeconds + 15 * 60 {
            return .comfortable
        }
        return .distant
    }

    private func baseScore(
        catchability: TransitOpportunityScore.Catchability,
        access: PersonalAccessEstimate?
    ) -> Double {
        let base: Double
        switch catchability {
        case .past: base = 0
        case .tooSoon: base = 0.18
        case .tight: base = 0.56
        case .comfortable: base = 0.76
        case .distant: base = 0.42
        case .unknown: base = 0.5
        }
        return base + (access?.confidence ?? 0) * 0.08
    }

    private func confidence(
        access: PersonalAccessEstimate?,
        biasCell: BiasCell?,
        feedScore: Double
    ) -> Double {
        let accessConfidence = access?.confidence ?? 0.25
        let biasConfidence = min(1, Double(biasCell?.count ?? 0) / 12)
        return accessConfidence * 0.5 + biasConfidence * 0.2 + feedScore * 0.3
    }

    private func alertPenalty(_ alerts: [ServiceAlert]) -> Double {
        alerts.reduce(0.0) { current, alert in
            let severity: Double
            switch alert.severity {
            case .low: severity = 0.04
            case .medium: severity = 0.12
            case .high: severity = 0.24
            }
            return max(current, alert.isMajor ? max(severity, 0.3) : severity)
        }
    }

    private func uncertaintyPenalty(_ cell: BiasCell?) -> Double {
        guard let stddev = cell?.standardDeviation else { return 0 }
        if stddev >= 5 * 60 { return 0.18 }
        if stddev >= 3 * 60 { return 0.1 }
        if stddev >= 2 * 60 { return 0.05 }
        return 0
    }
}
