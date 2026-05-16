import Foundation
import TransitModels

public struct PreparedDivvyClassicLeg: PreparedLegProcess {
    public let originStationId: String
    public let destinationStationId: String
    public let pickupProbability: Double
    public let dockProbability: Double
    public let rideMean: TimeInterval
    public let rideSigma: TimeInterval
    public let dockFullRecoverySeconds: TimeInterval
    public let dockFullRecoverySigmaSeconds: TimeInterval

    public init(
        originStationId: String,
        destinationStationId: String,
        pickupProbability: Double,
        dockProbability: Double,
        rideMean: TimeInterval,
        rideSigma: TimeInterval,
        dockFullRecoverySeconds: TimeInterval,
        dockFullRecoverySigmaSeconds: TimeInterval
    ) {
        self.originStationId = originStationId
        self.destinationStationId = destinationStationId
        self.pickupProbability = max(0, min(1, pickupProbability))
        self.dockProbability = max(0, min(1, dockProbability))
        self.rideMean = max(0, rideMean)
        self.rideSigma = max(0, rideSigma)
        self.dockFullRecoverySeconds = max(0, dockFullRecoverySeconds)
        self.dockFullRecoverySigmaSeconds = max(0, dockFullRecoverySigmaSeconds)
    }

    public func summary() -> TimeDistributionSummary {
        let dockFullPenalty = (1 - dockProbability) * dockFullRecoverySeconds
        let mean = rideMean + dockFullPenalty
        let recoveryVarianceContribution = (1 - dockProbability) * (dockFullRecoverySigmaSeconds * dockFullRecoverySigmaSeconds + dockFullRecoverySeconds * dockFullRecoverySeconds * dockProbability)
        let sigma = sqrt(rideSigma * rideSigma + recoveryVarianceContribution)
        let pickupFailurePenalty = 1 - pickupProbability
        return TimeDistributionSummary.analytic(
            mean: mean,
            standardDeviation: sigma,
            confidence: max(0.2, min(0.85, 1 - pickupFailurePenalty)),
            sampleCount: 0
        )
    }

    public func sample<G: RandomNumberGenerator>(startingAt: Date, rng: inout G) -> LegOutcome {
        _ = startingAt
        let pickupRoll = uniform(&rng)
        if pickupRoll > pickupProbability {
            return LegOutcome(
                totalDuration: 0,
                didFail: true,
                failureReason: "No usable classic Divvy at \(originStationId)."
            )
        }
        let ride = max(0, rideMean + nextGaussian(&rng) * rideSigma)
        let dockRoll = uniform(&rng)
        if dockRoll > dockProbability {
            let recovery = max(0, dockFullRecoverySeconds + nextGaussian(&rng) * dockFullRecoverySigmaSeconds)
            return LegOutcome(totalDuration: ride + recovery)
        }
        return LegOutcome(totalDuration: ride)
    }
}

public struct DivvyClassicKernel: LegKernel {
    public let originStationId: String
    public let destinationStationId: String
    public let provider: any DivvyPredictionProviding
    public let referenceTime: Date
    public let dockFullRecoverySeconds: TimeInterval
    public let dockFullRecoverySigmaSeconds: TimeInterval

    public init(
        originStationId: String,
        destinationStationId: String,
        provider: any DivvyPredictionProviding,
        referenceTime: Date = .now,
        dockFullRecoverySeconds: TimeInterval = 5 * 60,
        dockFullRecoverySigmaSeconds: TimeInterval = 60
    ) {
        self.originStationId = originStationId
        self.destinationStationId = destinationStationId
        self.provider = provider
        self.referenceTime = referenceTime
        self.dockFullRecoverySeconds = max(0, dockFullRecoverySeconds)
        self.dockFullRecoverySigmaSeconds = max(0, dockFullRecoverySigmaSeconds)
    }

    public func prepare() async -> PreparedDivvyClassicLeg {
        async let pickup = provider.usableBikeProbability(stationId: originStationId, at: referenceTime, kind: .classic)
        async let dock = provider.dockOpenProbability(stationId: destinationStationId, at: referenceTime)
        async let rideMean = provider.rideDurationSeconds(fromStationId: originStationId, toStationId: destinationStationId, at: referenceTime, kind: .classic)
        async let rideSigma = provider.rideDurationSigmaSeconds(fromStationId: originStationId, toStationId: destinationStationId, at: referenceTime, kind: .classic)
        let (p, d, rMean, rSigma) = await (pickup, dock, rideMean, rideSigma)
        return PreparedDivvyClassicLeg(
            originStationId: originStationId,
            destinationStationId: destinationStationId,
            pickupProbability: p,
            dockProbability: d,
            rideMean: rMean,
            rideSigma: rSigma,
            dockFullRecoverySeconds: dockFullRecoverySeconds,
            dockFullRecoverySigmaSeconds: dockFullRecoverySigmaSeconds
        )
    }
}

func uniform<G: RandomNumberGenerator>(_ rng: inout G) -> Double {
    Double(rng.next()) / Double(UInt64.max)
}
