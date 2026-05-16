import Foundation
import TransitModels

public struct PreparedTransitLeg: PreparedLegProcess {
    public let mode: LegMode
    public let stopArrivalProcess: StopArrivalProcess
    public let inVehicleMean: TimeInterval
    public let inVehicleSigma: TimeInterval
    public let waitSigmaFloorSeconds: TimeInterval
    public let waitSigmaCoefficient: Double
    public let missCutoffSeconds: TimeInterval

    public init(
        mode: LegMode,
        stopArrivalProcess: StopArrivalProcess,
        inVehicleMean: TimeInterval,
        inVehicleSigma: TimeInterval,
        waitSigmaFloorSeconds: TimeInterval = 30,
        waitSigmaCoefficient: Double = 0.25,
        missCutoffSeconds: TimeInterval = 30 * 60
    ) {
        self.mode = mode
        self.stopArrivalProcess = stopArrivalProcess
        self.inVehicleMean = max(0, inVehicleMean)
        self.inVehicleSigma = max(0, inVehicleSigma)
        self.waitSigmaFloorSeconds = max(0, waitSigmaFloorSeconds)
        self.waitSigmaCoefficient = max(0, waitSigmaCoefficient)
        self.missCutoffSeconds = max(0, missCutoffSeconds)
    }

    public func summary() -> TimeDistributionSummary {
        let forecast = stopArrivalProcess.waitDistribution(arrivingAt: stopArrivalProcess.generatedAt)
        let waitMean = forecast.waitDistribution.mean
        let waitSigma = waitSigmaForForecast(forecast)
        let combinedMean = waitMean + inVehicleMean
        let combinedSigma = sqrt(waitSigma * waitSigma + inVehicleSigma * inVehicleSigma)
        return TimeDistributionSummary.analytic(
            mean: combinedMean,
            standardDeviation: combinedSigma,
            confidence: forecast.waitDistribution.confidence,
            sampleCount: forecast.waitDistribution.sampleCount
        )
    }

    public func sample<G: RandomNumberGenerator>(startingAt: Date, rng: inout G) -> LegOutcome {
        let forecast = stopArrivalProcess.waitDistribution(arrivingAt: startingAt)
        let waitMean = forecast.waitDistribution.mean
        let waitSigma = waitSigmaForForecast(forecast)
        let waitSample = max(0, waitMean + nextGaussian(&rng) * waitSigma)

        if waitSample > missCutoffSeconds {
            return LegOutcome(
                totalDuration: waitSample,
                didFail: true,
                failureReason: "Wait exceeded cutoff — leg missed."
            )
        }

        let inVehicleSample = max(0, inVehicleMean + nextGaussian(&rng) * inVehicleSigma)
        return LegOutcome(totalDuration: waitSample + inVehicleSample)
    }

    private func waitSigmaForForecast(_ forecast: WaitForecast) -> TimeInterval {
        let baseline = max(waitSigmaFloorSeconds, forecast.waitDistribution.mean * waitSigmaCoefficient)
        switch forecast.state {
        case .feedUnreliable, .unknown:
            return baseline * 1.8
        case .badGap:
            return baseline * 1.4
        case .riskyWait:
            return baseline * 1.2
        case .bunched, .acceptableWait, .goodWait:
            return baseline
        }
    }
}

public struct TransitLegKernel: LegKernel {
    public let mode: LegMode
    public let stopArrivalProcess: StopArrivalProcess
    public let inVehicleMean: TimeInterval
    public let inVehicleSigma: TimeInterval
    public let waitSigmaFloorSeconds: TimeInterval
    public let waitSigmaCoefficient: Double
    public let missCutoffSeconds: TimeInterval

    public init(
        mode: LegMode,
        stopArrivalProcess: StopArrivalProcess,
        inVehicleMean: TimeInterval,
        inVehicleSigma: TimeInterval,
        waitSigmaFloorSeconds: TimeInterval = 30,
        waitSigmaCoefficient: Double = 0.25,
        missCutoffSeconds: TimeInterval = 30 * 60
    ) {
        self.mode = mode
        self.stopArrivalProcess = stopArrivalProcess
        self.inVehicleMean = inVehicleMean
        self.inVehicleSigma = inVehicleSigma
        self.waitSigmaFloorSeconds = waitSigmaFloorSeconds
        self.waitSigmaCoefficient = waitSigmaCoefficient
        self.missCutoffSeconds = missCutoffSeconds
    }

    public func prepare() async -> PreparedTransitLeg {
        PreparedTransitLeg(
            mode: mode,
            stopArrivalProcess: stopArrivalProcess,
            inVehicleMean: inVehicleMean,
            inVehicleSigma: inVehicleSigma,
            waitSigmaFloorSeconds: waitSigmaFloorSeconds,
            waitSigmaCoefficient: waitSigmaCoefficient,
            missCutoffSeconds: missCutoffSeconds
        )
    }
}
