import Foundation
import TransitModels

public enum FeedState: String, Sendable, Hashable, Codable, CaseIterable {
    case fresh
    case stale
    case missing
}

public struct LiveDeparture: Sendable, Hashable {
    public let arrivalAt: Date
    public let isApproaching: Bool
    public let isScheduled: Bool
    public let toneHint: ArrivalConfidenceMark.Tone

    public init(
        arrivalAt: Date,
        isApproaching: Bool = false,
        isScheduled: Bool = false,
        toneHint: ArrivalConfidenceMark.Tone = .normal
    ) {
        self.arrivalAt = arrivalAt
        self.isApproaching = isApproaching
        self.isScheduled = isScheduled
        self.toneHint = toneHint
    }
}

public struct WaitForecast: Sendable, Hashable {
    public let waitDistribution: TimeDistributionSummary
    public let state: WaitReasonableness
    public let nextDepartureAt: Date?
    public let pBoardWithin5Min: Double
    public let pBoardWithin10Min: Double
    public let pBoardWithin15Min: Double
    public let explanation: String?

    public init(
        waitDistribution: TimeDistributionSummary,
        state: WaitReasonableness,
        nextDepartureAt: Date?,
        pBoardWithin5Min: Double,
        pBoardWithin10Min: Double,
        pBoardWithin15Min: Double,
        explanation: String?
    ) {
        self.waitDistribution = waitDistribution
        self.state = state
        self.nextDepartureAt = nextDepartureAt
        self.pBoardWithin5Min = max(0, min(1, pBoardWithin5Min))
        self.pBoardWithin10Min = max(0, min(1, pBoardWithin10Min))
        self.pBoardWithin15Min = max(0, min(1, pBoardWithin15Min))
        self.explanation = explanation
    }
}

public struct StopArrivalProcess: Sendable {
    public let route: String
    public let direction: String?
    public let generatedAt: Date
    public let departures: [LiveDeparture]
    public let scheduleHeadwaySeconds: TimeInterval?
    public let feedState: FeedState

    public init(
        route: String,
        direction: String? = nil,
        generatedAt: Date,
        departures: [LiveDeparture],
        scheduleHeadwaySeconds: TimeInterval? = nil,
        feedState: FeedState = .fresh
    ) {
        self.route = route
        self.direction = direction
        self.generatedAt = generatedAt
        self.departures = departures.sorted { $0.arrivalAt < $1.arrivalAt }
        self.scheduleHeadwaySeconds = scheduleHeadwaySeconds
        self.feedState = feedState
    }

    public func waitDistribution(arrivingAt arrivalAt: Date) -> WaitForecast {
        let upcoming = departures.filter { $0.arrivalAt >= arrivalAt }

        if feedState == .missing || (upcoming.isEmpty && feedState == .fresh && scheduleHeadwaySeconds == nil) {
            return scheduleFallback(arrivalAt: arrivalAt, state: upcoming.isEmpty ? .unknown : .feedUnreliable)
        }

        if feedState == .stale {
            return scheduleFallback(arrivalAt: arrivalAt, state: .feedUnreliable)
        }

        guard let next = upcoming.first else {
            return scheduleFallback(arrivalAt: arrivalAt, state: .unknown)
        }

        let nextWait = max(0, next.arrivalAt.timeIntervalSince(arrivalAt))
        let gaps = consecutiveGaps(from: upcoming)
        let summary = waitSummary(nextWait: nextWait, gaps: gaps, sampleCount: upcoming.count)
        let state = classify(nextWait: nextWait, gaps: gaps, next: next)
        let explanation = explainState(state: state, nextWait: nextWait, gaps: gaps)
        return WaitForecast(
            waitDistribution: summary,
            state: state,
            nextDepartureAt: next.arrivalAt,
            pBoardWithin5Min: nextWait <= 5 * 60 ? 1.0 : 0.0,
            pBoardWithin10Min: nextWait <= 10 * 60 ? 1.0 : 0.0,
            pBoardWithin15Min: nextWait <= 15 * 60 ? 1.0 : 0.0,
            explanation: explanation
        )
    }

    private func scheduleFallback(arrivalAt: Date, state: WaitReasonableness) -> WaitForecast {
        _ = state
        guard let headway = scheduleHeadwaySeconds, headway > 0 else {
            return WaitForecast(
                waitDistribution: .zero,
                state: .unknown,
                nextDepartureAt: nil,
                pBoardWithin5Min: 0,
                pBoardWithin10Min: 0,
                pBoardWithin15Min: 0,
                explanation: "No live data and no schedule headway."
            )
        }
        let halfHeadway = headway / 2
        let summary = TimeDistributionSummary.analytic(
            mean: halfHeadway,
            standardDeviation: headway / 3,
            confidence: 0.4
        )
        let pBoard5 = saturating(rate: 1.0 / max(60, halfHeadway), seconds: 5 * 60)
        let pBoard10 = saturating(rate: 1.0 / max(60, halfHeadway), seconds: 10 * 60)
        let pBoard15 = saturating(rate: 1.0 / max(60, halfHeadway), seconds: 15 * 60)
        return WaitForecast(
            waitDistribution: summary,
            state: .feedUnreliable,
            nextDepartureAt: nil,
            pBoardWithin5Min: pBoard5,
            pBoardWithin10Min: pBoard10,
            pBoardWithin15Min: pBoard15,
            explanation: "Schedule-only estimate — half-headway."
        )
    }

    private func consecutiveGaps(from departures: [LiveDeparture]) -> [TimeInterval] {
        guard departures.count >= 2 else { return [] }
        var gaps: [TimeInterval] = []
        for i in 1..<departures.count {
            gaps.append(departures[i].arrivalAt.timeIntervalSince(departures[i - 1].arrivalAt))
        }
        return gaps
    }

    private func waitSummary(nextWait: TimeInterval, gaps: [TimeInterval], sampleCount: Int) -> TimeDistributionSummary {
        if gaps.isEmpty {
            return TimeDistributionSummary.analytic(
                mean: nextWait,
                standardDeviation: max(60, nextWait * 0.2),
                confidence: 0.55,
                sampleCount: sampleCount
            )
        }
        let median = medianOf(gaps)
        let sigma = max(45, median * 0.3)
        return TimeDistributionSummary.analytic(
            mean: nextWait,
            standardDeviation: sigma,
            confidence: min(1.0, 0.5 + Double(min(gaps.count, 4)) * 0.1),
            sampleCount: sampleCount
        )
    }

    private func classify(nextWait: TimeInterval, gaps: [TimeInterval], next: LiveDeparture) -> WaitReasonableness {
        if next.isApproaching { return .goodWait }
        if nextWait <= 4 * 60 { return .goodWait }

        if gaps.count >= 2 {
            let median = medianOf(Array(gaps.dropFirst()))
            let firstGap = gaps[0]
            if median > 0, firstGap > 0, firstGap < 0.5 * median, firstGap <= 4 * 60 {
                return .bunched
            }
            let gap = gaps[0]
            if median > 0, gap > 2.0 * median, gap > 12 * 60 {
                return .badGap
            }
        }

        if nextWait > 12 * 60 { return .badGap }
        if nextWait > 7 * 60 { return .riskyWait }
        return .acceptableWait
    }

    private func explainState(state: WaitReasonableness, nextWait: TimeInterval, gaps: [TimeInterval]) -> String {
        let mins = Int((nextWait / 60).rounded())
        switch state {
        case .goodWait: return "Next departure in \(mins) min."
        case .acceptableWait: return "Reasonable wait — \(mins) min."
        case .riskyWait: return "Cutting it close — \(mins) min away."
        case .badGap: return "Long gap — \(mins) min wait."
        case .bunched: return "Bunched arrivals — next \(mins) min, then another close behind."
        case .feedUnreliable: return "Feed unreliable — estimate widened."
        case .unknown: return "Not enough data to judge wait."
        }
    }

    private func saturating(rate: Double, seconds: TimeInterval) -> Double {
        let p = 1 - exp(-rate * seconds)
        return max(0, min(1, p))
    }
}

func medianOf(_ values: [TimeInterval]) -> TimeInterval {
    if values.isEmpty { return 0 }
    let sorted = values.sorted()
    let n = sorted.count
    if n % 2 == 1 { return sorted[n / 2] }
    return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
}
