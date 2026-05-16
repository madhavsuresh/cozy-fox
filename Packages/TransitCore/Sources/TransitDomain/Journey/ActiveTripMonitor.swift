import Foundation
import TransitModels

public actor ActiveTripMonitor {
    private var session: ActiveTripSession?
    private var hysteresisState: HysteresisState?

    private let beliefUpdater: OptionBeliefUpdater
    private let choicePointDetector: ChoicePointDetector
    private let hysteresis: RecommendationHysteresis
    private let ranker: any PolicyRanker

    public init(
        beliefUpdater: OptionBeliefUpdater = OptionBeliefUpdater(),
        choicePointDetector: ChoicePointDetector = ChoicePointDetector(),
        hysteresis: RecommendationHysteresis = RecommendationHysteresis(),
        ranker: any PolicyRanker = LowestP80Ranker()
    ) {
        self.beliefUpdater = beliefUpdater
        self.choicePointDetector = choicePointDetector
        self.hysteresis = hysteresis
        self.ranker = ranker
    }

    public func start(
        destinationTitle: String,
        candidateOptions: [JourneyOption],
        at startedAt: Date
    ) {
        let n = max(1, candidateOptions.count)
        let uniform = 1.0 / Double(n)
        let beliefs: [UUID: Double] = Dictionary(
            uniqueKeysWithValues: candidateOptions.map { ($0.id, uniform) }
        )
        session = ActiveTripSession(
            destinationTitle: destinationTitle,
            startedAt: startedAt,
            phase: .notStarted,
            candidateOptionIDs: candidateOptions.map(\.id),
            optionBeliefs: beliefs,
            inferredOptionID: nil,
            pendingChoicePointIDs: [],
            currentRecommendationOptionID: nil,
            lastUpdatedAt: startedAt
        )
        hysteresisState = HysteresisState(lastEvaluatedAt: startedAt)
    }

    public func tick(
        userPosition: PlannerCoordinate?,
        candidateOptions: [JourneyOption],
        distributions: [UUID: JourneyDistribution],
        now: Date,
        bypass: RecommendationHysteresis.BypassReason? = nil
    ) -> ActiveTripSession? {
        guard let existing = session else { return nil }

        let newBeliefs = beliefUpdater.update(
            currentBeliefs: existing.optionBeliefs,
            userPosition: userPosition,
            options: candidateOptions
        )
        let inferred = newBeliefs.max(by: { $0.value < $1.value })?.key

        let rankableInputs: [(option: JourneyOption, distribution: JourneyDistribution)] = candidateOptions
            .compactMap { option in
                guard let dist = distributions[option.id] else { return nil }
                return (option, dist)
            }
        let ranked = ranker.rank(rankableInputs)

        let priorHysteresis = hysteresisState ?? HysteresisState(lastEvaluatedAt: now)
        let nextHysteresis = hysteresis.step(state: priorHysteresis, ranked: ranked, now: now, bypass: bypass)
        hysteresisState = nextHysteresis

        let currentRecommendation = nextHysteresis.currentRecommendationID
        let recommendedOption = candidateOptions.first(where: { $0.id == currentRecommendation })
        let pending = recommendedOption.map { choicePointDetector.detect(in: $0, userPosition: userPosition, now: now) } ?? []

        let phase = inferPhase(
            existing: existing,
            userPosition: userPosition,
            recommendedOption: recommendedOption,
            now: now
        )

        let updated = ActiveTripSession(
            id: existing.id,
            destinationTitle: existing.destinationTitle,
            startedAt: existing.startedAt,
            phase: phase,
            candidateOptionIDs: existing.candidateOptionIDs,
            optionBeliefs: newBeliefs,
            inferredOptionID: inferred,
            pendingChoicePointIDs: pending.map(\.id),
            currentRecommendationOptionID: currentRecommendation,
            lastUpdatedAt: now
        )
        session = updated
        return updated
    }

    public func end() {
        session = nil
        hysteresisState = nil
    }

    public func currentSession() -> ActiveTripSession? {
        session
    }

    public func currentHysteresisState() -> HysteresisState? {
        hysteresisState
    }

    private func inferPhase(
        existing: ActiveTripSession,
        userPosition: PlannerCoordinate?,
        recommendedOption: JourneyOption?,
        now: Date
    ) -> ActiveTripPhase {
        guard let userPosition, let recommendedOption else { return existing.phase }
        let walkingThresholdMeters: Double = 80
        let waitingThresholdMeters: Double = 30
        let firstBoarding = recommendedOption.slots.first.flatMap { slot -> JourneyPoint? in
            switch slot {
            case .fixed(let leg): return leg.toPoint
            case .exchangeable(let alts, _): return alts.first?.toPoint
            }
        }?.coordinate
        guard let firstBoarding else { return existing.phase }
        let distance = haversineMeters(
            from: (userPosition.latitude, userPosition.longitude),
            to: (firstBoarding.latitude, firstBoarding.longitude)
        )
        if distance <= waitingThresholdMeters { return .waitingForVehicle }
        if distance <= walkingThresholdMeters { return .walkingToFirstLeg }
        if existing.phase == .notStarted { return .walkingToFirstLeg }
        return existing.phase
    }
}
