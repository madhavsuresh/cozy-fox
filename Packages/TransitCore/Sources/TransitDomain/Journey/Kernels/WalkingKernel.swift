import Foundation
import TransitModels

public struct PreparedWalkProcess: PreparedLegProcess {
    public let expectedSeconds: TimeInterval
    public let appliedRatio: Double
    public let jitterCoefficient: Double
    public let confidence: Double
    public let sampleCount: Int

    public init(
        expectedSeconds: TimeInterval,
        appliedRatio: Double,
        jitterCoefficient: Double,
        confidence: Double,
        sampleCount: Int
    ) {
        self.expectedSeconds = max(0, expectedSeconds)
        self.appliedRatio = max(0.1, appliedRatio)
        self.jitterCoefficient = max(0, jitterCoefficient)
        self.confidence = max(0, min(1, confidence))
        self.sampleCount = max(0, sampleCount)
    }

    public var meanSeconds: TimeInterval { expectedSeconds * appliedRatio }

    public var sigmaSeconds: TimeInterval { meanSeconds * jitterCoefficient }

    public func summary() -> TimeDistributionSummary {
        TimeDistributionSummary.analytic(
            mean: meanSeconds,
            standardDeviation: sigmaSeconds,
            confidence: confidence,
            sampleCount: sampleCount
        )
    }

    public func sample<G: RandomNumberGenerator>(startingAt: Date, rng: inout G) -> LegOutcome {
        _ = startingAt
        let z = nextGaussian(&rng)
        let raw = meanSeconds + z * sigmaSeconds
        return LegOutcome(totalDuration: max(0, raw))
    }
}

public struct WalkingKernel: LegKernel {
    public let expectedSeconds: TimeInterval
    public let walkSpeedEstimate: WalkSpeedEstimate
    public let jitterCoefficient: Double
    public let minSamplesForConfidentRatio: Int

    public init(
        expectedSeconds: TimeInterval,
        walkSpeedEstimate: WalkSpeedEstimate,
        jitterCoefficient: Double = 0.10,
        minSamplesForConfidentRatio: Int = 5
    ) {
        self.expectedSeconds = max(0, expectedSeconds)
        self.walkSpeedEstimate = walkSpeedEstimate
        self.jitterCoefficient = max(0, jitterCoefficient)
        self.minSamplesForConfidentRatio = max(1, minSamplesForConfidentRatio)
    }

    public func prepare() async -> PreparedWalkProcess {
        let ratio = walkSpeedEstimate.confidentRatio(minSamples: minSamplesForConfidentRatio) ?? 1.0
        let confidence: Double = walkSpeedEstimate.count >= minSamplesForConfidentRatio
            ? min(1.0, 0.5 + Double(walkSpeedEstimate.count) / 60.0)
            : 0.5
        return PreparedWalkProcess(
            expectedSeconds: expectedSeconds,
            appliedRatio: ratio,
            jitterCoefficient: jitterCoefficient,
            confidence: confidence,
            sampleCount: walkSpeedEstimate.count
        )
    }
}
