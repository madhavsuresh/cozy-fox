import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("JourneyComposer")
struct JourneyComposerTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func leg(_ mode: LegMode = .walk, label: String = "leg") -> LegCandidate {
        LegCandidate(
            mode: mode,
            displayLabel: label,
            fromPoint: .anchor(.home),
            toPoint: .anchor(.work)
        )
    }

    @Test func singleWalkSlotComposesToWalkOutcome() async {
        let composer = JourneyComposer()
        let walk = leg(.walk, label: "walk to work")
        let option = JourneyOption(title: "walk", summary: "walk only", slots: [.fixed(walk)])
        let walkKernel = WalkingKernel(expectedSeconds: 600, walkSpeedEstimate: .empty, jitterCoefficient: 0)
        let prepared: any PreparedLegProcess = await walkKernel.prepare()
        var rng = SeededLCG(seed: 1)
        let distribution = composer.compose(
            option: option,
            legProcesses: [walk.id: prepared],
            startingAt: Self.t0,
            samples: 200,
            rng: &rng
        )
        #expect(abs(distribution.totalDuration.p50 - 600) < 30)
        #expect(distribution.failureProbability == 0)
    }

    @Test func walkPlusTransitComposesAdditively() async {
        let composer = JourneyComposer()
        let walk = leg(.walk, label: "walk to stop")
        let train = leg(.ctaTrain, label: "Red Line ride")
        let option = JourneyOption(
            title: "walk + Red",
            summary: "two legs",
            slots: [.fixed(walk), .fixed(train)]
        )
        let walkPrepared: any PreparedLegProcess = await WalkingKernel(
            expectedSeconds: 300, walkSpeedEstimate: .empty, jitterCoefficient: 0
        ).prepare()
        let trainPrepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: StopArrivalProcess(
                route: "Red",
                generatedAt: Self.t0,
                departures: (1...5).map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(Double($0) * 6 * 60 + 300)) }
            ),
            inVehicleMean: 1200,
            inVehicleSigma: 30
        ).prepare()
        var rng = SeededLCG(seed: 9)
        let distribution = composer.compose(
            option: option,
            legProcesses: [walk.id: walkPrepared, train.id: trainPrepared],
            startingAt: Self.t0,
            samples: 256,
            rng: &rng
        )
        let expected: TimeInterval = 300 + 360 + 1200
        #expect(abs(distribution.totalDuration.p50 - expected) < 90)
    }

    @Test func missedConnectionPropagatesAsFailure() async {
        let composer = JourneyComposer()
        let walk = leg(.walk, label: "long walk")
        let train = leg(.ctaTrain, label: "Red Line")
        let option = JourneyOption(
            title: "miss the train",
            summary: "walk too long",
            slots: [.fixed(walk), .fixed(train)]
        )
        let walkPrepared: any PreparedLegProcess = await WalkingKernel(
            expectedSeconds: 3000, walkSpeedEstimate: .empty, jitterCoefficient: 0
        ).prepare()
        let trainPrepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: StopArrivalProcess(
                route: "Red",
                generatedAt: Self.t0,
                departures: [LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(90 * 60))],
                feedState: .fresh
            ),
            inVehicleMean: 600,
            inVehicleSigma: 30,
            missCutoffSeconds: 10 * 60
        ).prepare()
        var rng = SeededLCG(seed: 11)
        let distribution = composer.compose(
            option: option,
            legProcesses: [walk.id: walkPrepared, train.id: trainPrepared],
            startingAt: Self.t0,
            samples: 256,
            rng: &rng
        )
        #expect(distribution.failureProbability > 0.5)
        #expect(distribution.dominantFailureReason?.contains("missed") == true)
    }

    @Test func compositionIsDeterministicForFixedSeed() async {
        let composer = JourneyComposer()
        let train = leg(.ctaTrain, label: "Red")
        let option = JourneyOption(title: "Red only", summary: "", slots: [.fixed(train)])
        let prepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: StopArrivalProcess(
                route: "Red",
                generatedAt: Self.t0,
                departures: (1...5).map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(Double($0) * 8 * 60)) }
            ),
            inVehicleMean: 1200,
            inVehicleSigma: 60
        ).prepare()
        var rngA = SeededLCG(seed: 23)
        var rngB = SeededLCG(seed: 23)
        let distA = composer.compose(option: option, legProcesses: [train.id: prepared], startingAt: Self.t0, samples: 256, rng: &rngA)
        let distB = composer.compose(option: option, legProcesses: [train.id: prepared], startingAt: Self.t0, samples: 256, rng: &rngB)
        #expect(distA == distB)
    }

    @Test func missingKernelReturnsImmediateFailure() {
        let composer = JourneyComposer()
        let train = leg(.ctaTrain, label: "Red")
        let option = JourneyOption(title: "Red only", summary: "", slots: [.fixed(train)])
        var rng = SeededLCG(seed: 7)
        let outcome = composer.sample(
            option: option,
            legProcesses: [:],
            startingAt: Self.t0,
            rng: &rng
        )
        #expect(outcome.didFail)
        #expect(outcome.failureSlotIndex == 0)
    }
}
