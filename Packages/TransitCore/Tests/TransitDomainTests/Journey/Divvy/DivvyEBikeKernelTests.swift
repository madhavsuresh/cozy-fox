import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("DivvyEBikeKernel")
struct DivvyEBikeKernelTests {
    private let destinationCoord = PlannerCoordinate(latitude: 42.04, longitude: -87.68)

    @Test func freeParkAllowedKeepsRecoveryShortWhenDockFull() async {
        let provider = DivvyPredictionStub(
            usableEbikeProbability: 1.0,
            dockProbability: 0.0,
            freeParkAllowed: true,
            ebikeRideMean: 420,
            ebikeRideSigma: 0
        )
        let kernel = DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: provider,
            freeParkExtraWalkSeconds: 90,
            dockFullRecoverySeconds: 300
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(!outcome.didFail)
        #expect(outcome.totalDuration < 420 + 300)
    }

    @Test func freeParkDisallowedTriggersDockRecoveryWhenDockFull() async {
        let provider = DivvyPredictionStub(
            usableEbikeProbability: 1.0,
            dockProbability: 0.0,
            freeParkAllowed: false,
            ebikeRideMean: 420,
            ebikeRideSigma: 0
        )
        let kernel = DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: provider,
            freeParkExtraWalkSeconds: 0,
            dockFullRecoverySeconds: 300,
            dockFullRecoverySigmaSeconds: 0
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(!outcome.didFail)
        #expect(outcome.totalDuration == 720)
    }

    @Test func pickupFailureMarksLegAsFailed() async {
        let provider = DivvyPredictionStub(
            usableEbikeProbability: 0.0,
            freeParkAllowed: true
        )
        let kernel = DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: provider
        )
        let prepared = await kernel.prepare()
        var rng = SeededLCG(seed: 1)
        let outcome = prepared.sample(startingAt: .distantPast, rng: &rng)
        #expect(outcome.didFail)
        #expect(outcome.failureReason?.contains("e-Divvy") == true)
    }

    @Test func summaryConfidenceTracksPickupProbability() async {
        let highP = await DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: DivvyPredictionStub(usableEbikeProbability: 0.9)
        ).prepare()
        let lowP = await DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: DivvyPredictionStub(usableEbikeProbability: 0.3)
        ).prepare()
        #expect(highP.summary().confidence > lowP.summary().confidence)
    }

    @Test func ebikeRidesFasterThanClassicAtSameStations() async {
        let provider = DivvyPredictionStub(
            classicRideMean: 720,
            ebikeRideMean: 420
        )
        let classic = await DivvyClassicKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            provider: provider
        ).prepare()
        let ebike = await DivvyEBikeKernel(
            originStationId: "TA1",
            destinationStationId: "TA2",
            destinationCoordinate: destinationCoord,
            provider: provider
        ).prepare()
        #expect(ebike.summary().mean < classic.summary().mean)
    }
}
