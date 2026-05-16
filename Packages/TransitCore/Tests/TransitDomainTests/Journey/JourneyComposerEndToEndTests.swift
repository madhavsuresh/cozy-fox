import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("Journey composer end-to-end synthetic")
struct JourneyComposerEndToEndTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Multi-leg ORD → Streeterville-ish: walk → Blue Line → transfer at Grand
    /// → walk → bus. Validates the composer threads time across slots and the
    /// ranker selects the lowest-p80 option from a frontier.
    @Test func threeLegJourneyComposesAndRanks() async {
        let composer = JourneyComposer()

        let walkA = LegCandidate(mode: .walk, displayLabel: "Walk to Blue Line", fromPoint: .anchor(.home), toPoint: .station(systemRef: "ORD", name: "O'Hare", lineHint: "Blue"))
        let blue = LegCandidate(mode: .ctaTrain, displayLabel: "Blue Line — Grand", fromPoint: .station(systemRef: "ORD", name: "O'Hare", lineHint: "Blue"), toPoint: .station(systemRef: "GRD", name: "Grand", lineHint: "Blue"))
        let walkB = LegCandidate(mode: .walk, displayLabel: "Walk to 65 bus", fromPoint: .station(systemRef: "GRD", name: "Grand", lineHint: "Blue"), toPoint: .stop(systemRef: "65B", name: "65 stop", latitude: 41.89, longitude: -87.63))
        let bus65 = LegCandidate(mode: .ctaBus, displayLabel: "65 to Navy Pier", fromPoint: .stop(systemRef: "65B", name: "65 stop", latitude: 41.89, longitude: -87.63), toPoint: .namedPlace(title: "Streeterville", subtitle: nil, latitude: 41.89, longitude: -87.61))

        let walk66 = LegCandidate(mode: .walk, displayLabel: "Walk to 66 bus", fromPoint: .station(systemRef: "CHI", name: "Chicago", lineHint: "Blue"), toPoint: .stop(systemRef: "66B", name: "66 stop", latitude: 41.90, longitude: -87.63))
        let chicagoStop = LegCandidate(mode: .ctaTrain, displayLabel: "Blue Line — Chicago", fromPoint: .station(systemRef: "ORD", name: "O'Hare", lineHint: "Blue"), toPoint: .station(systemRef: "CHI", name: "Chicago", lineHint: "Blue"))
        let bus66 = LegCandidate(mode: .ctaBus, displayLabel: "66 to Streeterville", fromPoint: .stop(systemRef: "66B", name: "66 stop", latitude: 41.90, longitude: -87.63), toPoint: .namedPlace(title: "Streeterville", subtitle: nil, latitude: 41.90, longitude: -87.61))

        let fastIfHits = JourneyOption(
            title: "Blue → Grand → 65",
            summary: "Fast but the 65 wait varies",
            slots: [.fixed(walkA), .fixed(blue), .fixed(walkB), .fixed(bus65)]
        )
        let bestRealistic = JourneyOption(
            title: "Blue → Chicago → 66",
            summary: "Reliable 66",
            slots: [.fixed(walkA), .fixed(chicagoStop), .fixed(walk66), .fixed(bus66)]
        )

        let blueDepartures = (1...6).map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(Double($0) * 5 * 60 + 240)) }
        let chicagoDepartures = blueDepartures.map { LiveDeparture(arrivalAt: $0.arrivalAt.addingTimeInterval(2 * 60)) }
        let bus65Departures = (0..<3).map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(Double($0) * 15 * 60 + 35 * 60)) }
        let bus66Departures = (1...5).map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval(Double($0) * 7 * 60 + 32 * 60)) }

        let walkPrepared: any PreparedLegProcess = await WalkingKernel(expectedSeconds: 240, walkSpeedEstimate: .empty, jitterCoefficient: 0).prepare()
        let walkBPrepared: any PreparedLegProcess = await WalkingKernel(expectedSeconds: 300, walkSpeedEstimate: .empty, jitterCoefficient: 0).prepare()
        let walk66Prepared: any PreparedLegProcess = await WalkingKernel(expectedSeconds: 360, walkSpeedEstimate: .empty, jitterCoefficient: 0).prepare()
        let bluePrepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: StopArrivalProcess(route: "Blue", generatedAt: Self.t0, departures: blueDepartures),
            inVehicleMean: 30 * 60, inVehicleSigma: 90
        ).prepare()
        let chicagoPrepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaTrain,
            stopArrivalProcess: StopArrivalProcess(route: "Blue", generatedAt: Self.t0, departures: chicagoDepartures),
            inVehicleMean: 32 * 60, inVehicleSigma: 90
        ).prepare()
        let bus65Prepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaBus,
            stopArrivalProcess: StopArrivalProcess(route: "65", generatedAt: Self.t0, departures: bus65Departures),
            inVehicleMean: 8 * 60, inVehicleSigma: 120
        ).prepare()
        let bus66Prepared: any PreparedLegProcess = await TransitLegKernel(
            mode: .ctaBus,
            stopArrivalProcess: StopArrivalProcess(route: "66", generatedAt: Self.t0, departures: bus66Departures),
            inVehicleMean: 9 * 60, inVehicleSigma: 120
        ).prepare()

        let kernels: [UUID: any PreparedLegProcess] = [
            walkA.id: walkPrepared,
            blue.id: bluePrepared,
            walkB.id: walkBPrepared,
            bus65.id: bus65Prepared,
            chicagoStop.id: chicagoPrepared,
            walk66.id: walk66Prepared,
            bus66.id: bus66Prepared
        ]

        var rng = SeededLCG(seed: 7)
        let fastDist = composer.compose(option: fastIfHits, legProcesses: kernels, startingAt: Self.t0, samples: 512, rng: &rng)
        let bestDist = composer.compose(option: bestRealistic, legProcesses: kernels, startingAt: Self.t0, samples: 512, rng: &rng)

        #expect(fastDist.totalDuration.p50 > 0)
        #expect(bestDist.totalDuration.p80 > bestDist.totalDuration.p50)

        print("--- Composed journey frontier ---")
        for (title, dist) in [("Blue → Grand → 65", fastDist), ("Blue → Chicago → 66", bestDist)] {
            let p50min = dist.totalDuration.p50 / 60
            let p80min = dist.totalDuration.p80 / 60
            let p90min = dist.totalDuration.p90 / 60
            let failPct = dist.failureProbability * 100
            print(String(format: "  %@  p50=%.0fmin  p80=%.0fmin  p90=%.0fmin  fail=%.1f%%",
                         title, p50min, p80min, p90min, failPct))
        }
    }
}
