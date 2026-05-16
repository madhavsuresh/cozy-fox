import Foundation
import TransitModels

public struct PreparedDivvyEBikeLeg: PreparedLegProcess {
    public let originStationId: String
    public let destinationStationId: String
    public let pickupProbability: Double
    public let dockProbability: Double
    public let freeParkAllowed: Bool
    public let rideMean: TimeInterval
    public let rideSigma: TimeInterval
    public let freeParkExtraWalkSeconds: TimeInterval
    public let dockFullRecoverySeconds: TimeInterval
    public let dockFullRecoverySigmaSeconds: TimeInterval

    public init(
        originStationId: String,
        destinationStationId: String,
        pickupProbability: Double,
        dockProbability: Double,
        freeParkAllowed: Bool,
        rideMean: TimeInterval,
        rideSigma: TimeInterval,
        freeParkExtraWalkSeconds: TimeInterval,
        dockFullRecoverySeconds: TimeInterval,
        dockFullRecoverySigmaSeconds: TimeInterval
    ) {
        self.originStationId = originStationId
        self.destinationStationId = destinationStationId
        self.pickupProbability = max(0, min(1, pickupProbability))
        self.dockProbability = max(0, min(1, dockProbability))
        self.freeParkAllowed = freeParkAllowed
        self.rideMean = max(0, rideMean)
        self.rideSigma = max(0, rideSigma)
        self.freeParkExtraWalkSeconds = max(0, freeParkExtraWalkSeconds)
        self.dockFullRecoverySeconds = max(0, dockFullRecoverySeconds)
        self.dockFullRecoverySigmaSeconds = max(0, dockFullRecoverySigmaSeconds)
    }

    public func summary() -> TimeDistributionSummary {
        let dockFailExpected = freeParkAllowed ? freeParkExtraWalkSeconds : dockFullRecoverySeconds
        let mean = rideMean + (1 - dockProbability) * dockFailExpected
        let recoverySigma: TimeInterval = freeParkAllowed ? 30 : dockFullRecoverySigmaSeconds
        let sigma = sqrt(rideSigma * rideSigma + (1 - dockProbability) * recoverySigma * recoverySigma)
        return TimeDistributionSummary.analytic(
            mean: mean,
            standardDeviation: sigma,
            confidence: max(0.2, min(0.85, pickupProbability)),
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
                failureReason: "No usable e-Divvy at \(originStationId)."
            )
        }
        let ride = max(0, rideMean + nextGaussian(&rng) * rideSigma)
        let dockRoll = uniform(&rng)
        if dockRoll > dockProbability {
            if freeParkAllowed {
                let walk = max(0, freeParkExtraWalkSeconds + nextGaussian(&rng) * 30)
                return LegOutcome(totalDuration: ride + walk)
            }
            let recovery = max(0, dockFullRecoverySeconds + nextGaussian(&rng) * dockFullRecoverySigmaSeconds)
            return LegOutcome(totalDuration: ride + recovery)
        }
        return LegOutcome(totalDuration: ride)
    }
}

public struct DivvyEBikeKernel: LegKernel {
    public let originStationId: String
    public let destinationStationId: String
    public let destinationCoordinate: PlannerCoordinate
    public let provider: any DivvyPredictionProviding
    public let referenceTime: Date
    public let freeParkExtraWalkSeconds: TimeInterval
    public let dockFullRecoverySeconds: TimeInterval
    public let dockFullRecoverySigmaSeconds: TimeInterval

    public init(
        originStationId: String,
        destinationStationId: String,
        destinationCoordinate: PlannerCoordinate,
        provider: any DivvyPredictionProviding,
        referenceTime: Date = .now,
        freeParkExtraWalkSeconds: TimeInterval = 90,
        dockFullRecoverySeconds: TimeInterval = 5 * 60,
        dockFullRecoverySigmaSeconds: TimeInterval = 60
    ) {
        self.originStationId = originStationId
        self.destinationStationId = destinationStationId
        self.destinationCoordinate = destinationCoordinate
        self.provider = provider
        self.referenceTime = referenceTime
        self.freeParkExtraWalkSeconds = max(0, freeParkExtraWalkSeconds)
        self.dockFullRecoverySeconds = max(0, dockFullRecoverySeconds)
        self.dockFullRecoverySigmaSeconds = max(0, dockFullRecoverySigmaSeconds)
    }

    public func prepare() async -> PreparedDivvyEBikeLeg {
        async let pickup = provider.usableBikeProbability(stationId: originStationId, at: referenceTime, kind: .ebike)
        async let dock = provider.dockOpenProbability(stationId: destinationStationId, at: referenceTime)
        async let freePark = provider.freeBikeParkingAllowed(near: destinationCoordinate, at: referenceTime)
        async let rideMean = provider.rideDurationSeconds(fromStationId: originStationId, toStationId: destinationStationId, at: referenceTime, kind: .ebike)
        async let rideSigma = provider.rideDurationSigmaSeconds(fromStationId: originStationId, toStationId: destinationStationId, at: referenceTime, kind: .ebike)
        let (p, d, fp, rMean, rSigma) = await (pickup, dock, freePark, rideMean, rideSigma)
        return PreparedDivvyEBikeLeg(
            originStationId: originStationId,
            destinationStationId: destinationStationId,
            pickupProbability: p,
            dockProbability: d,
            freeParkAllowed: fp,
            rideMean: rMean,
            rideSigma: rSigma,
            freeParkExtraWalkSeconds: freeParkExtraWalkSeconds,
            dockFullRecoverySeconds: dockFullRecoverySeconds,
            dockFullRecoverySigmaSeconds: dockFullRecoverySigmaSeconds
        )
    }
}
