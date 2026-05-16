import Foundation
import TransitModels

public struct HysteresisState: Sendable, Hashable {
    public let currentRecommendationID: UUID?
    public let pendingRecommendationID: UUID?
    public let pendingSince: Date?
    public let lastEvaluatedAt: Date

    public init(
        currentRecommendationID: UUID? = nil,
        pendingRecommendationID: UUID? = nil,
        pendingSince: Date? = nil,
        lastEvaluatedAt: Date
    ) {
        self.currentRecommendationID = currentRecommendationID
        self.pendingRecommendationID = pendingRecommendationID
        self.pendingSince = pendingSince
        self.lastEvaluatedAt = lastEvaluatedAt
    }
}

public struct RecommendationHysteresis: Sendable {
    public let sustainSeconds: TimeInterval
    public let p80GapThresholdSeconds: TimeInterval

    public init(
        sustainSeconds: TimeInterval = 30,
        p80GapThresholdSeconds: TimeInterval = 60
    ) {
        self.sustainSeconds = max(0, sustainSeconds)
        self.p80GapThresholdSeconds = max(0, p80GapThresholdSeconds)
    }

    public enum BypassReason: Sendable, Hashable {
        case lastGoodOption
        case routeCollapse
        case hardDeadlineAtRisk
        case wrongDirection
        case activeTripOffPlan
    }

    public func step(
        state: HysteresisState,
        ranked: [RankedJourney],
        now: Date,
        bypass: BypassReason? = nil
    ) -> HysteresisState {
        guard let top = ranked.first else {
            return HysteresisState(
                currentRecommendationID: nil,
                pendingRecommendationID: nil,
                pendingSince: nil,
                lastEvaluatedAt: now
            )
        }
        let topID = top.option.id

        guard let currentID = state.currentRecommendationID else {
            return HysteresisState(
                currentRecommendationID: topID,
                pendingRecommendationID: nil,
                pendingSince: nil,
                lastEvaluatedAt: now
            )
        }

        if topID == currentID {
            return HysteresisState(
                currentRecommendationID: currentID,
                pendingRecommendationID: nil,
                pendingSince: nil,
                lastEvaluatedAt: now
            )
        }

        if bypass != nil {
            return HysteresisState(
                currentRecommendationID: topID,
                pendingRecommendationID: nil,
                pendingSince: nil,
                lastEvaluatedAt: now
            )
        }

        let currentP80 = ranked.first(where: { $0.option.id == currentID })?.distribution.totalDuration.p80 ?? .greatestFiniteMagnitude
        let topP80 = top.distribution.totalDuration.p80
        let gap = currentP80 - topP80
        if gap < p80GapThresholdSeconds {
            return HysteresisState(
                currentRecommendationID: currentID,
                pendingRecommendationID: nil,
                pendingSince: nil,
                lastEvaluatedAt: now
            )
        }

        if state.pendingRecommendationID == topID, let pendingSince = state.pendingSince {
            let elapsed = now.timeIntervalSince(pendingSince)
            if elapsed >= sustainSeconds {
                return HysteresisState(
                    currentRecommendationID: topID,
                    pendingRecommendationID: nil,
                    pendingSince: nil,
                    lastEvaluatedAt: now
                )
            }
            return HysteresisState(
                currentRecommendationID: currentID,
                pendingRecommendationID: topID,
                pendingSince: pendingSince,
                lastEvaluatedAt: now
            )
        }

        return HysteresisState(
            currentRecommendationID: currentID,
            pendingRecommendationID: topID,
            pendingSince: now,
            lastEvaluatedAt: now
        )
    }
}
