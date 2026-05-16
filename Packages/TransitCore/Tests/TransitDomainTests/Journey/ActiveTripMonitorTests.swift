import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("ActiveTripMonitor")
struct ActiveTripMonitorTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func option(_ name: String, boardingLat: Double = 41.9, boardingLon: Double = -87.65) -> JourneyOption {
        let leg = LegCandidate(
            mode: .ctaTrain,
            displayLabel: name,
            fromPoint: .anchor(.home),
            toPoint: .coordinate(latitude: boardingLat, longitude: boardingLon)
        )
        return JourneyOption(title: name, summary: name, slots: [.fixed(leg)])
    }

    private func distribution(p80: TimeInterval) -> JourneyDistribution {
        JourneyDistribution(
            totalDuration: TimeDistributionSummary(
                mean: p80, p50: p80, p80: p80, p90: p80 + 60,
                confidence: 0.7, sampleCount: 64
            ),
            failureProbability: 0,
            samples: 64
        )
    }

    @Test func startInitializesSessionWithUniformBeliefs() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A")
        let optB = option("B")
        await monitor.start(destinationTitle: "Work", candidateOptions: [optA, optB], at: Self.t0)
        let session = await monitor.currentSession()
        #expect(session?.candidateOptionIDs.count == 2)
        #expect(abs((session?.optionBeliefs[optA.id] ?? 0) - 0.5) < 0.001)
    }

    @Test func tickUpdatesRecommendationFromRankedFrontier() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A", boardingLat: 41.9, boardingLon: -87.65)
        let optB = option("B", boardingLat: 42.0, boardingLon: -87.7)
        await monitor.start(destinationTitle: "Work", candidateOptions: [optA, optB], at: Self.t0)
        let session = await monitor.tick(
            userPosition: nil,
            candidateOptions: [optA, optB],
            distributions: [optA.id: distribution(p80: 1500), optB.id: distribution(p80: 1700)],
            now: Self.t0.addingTimeInterval(10)
        )
        #expect(session?.currentRecommendationOptionID == optA.id)
    }

    @Test func proximityShiftsInferredOption() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A", boardingLat: 41.9, boardingLon: -87.65)
        let optB = option("B", boardingLat: 42.0, boardingLon: -87.7)
        await monitor.start(destinationTitle: "Work", candidateOptions: [optA, optB], at: Self.t0)
        let session = await monitor.tick(
            userPosition: PlannerCoordinate(latitude: 42.0, longitude: -87.7),
            candidateOptions: [optA, optB],
            distributions: [optA.id: distribution(p80: 1500), optB.id: distribution(p80: 1700)],
            now: Self.t0.addingTimeInterval(10)
        )
        #expect(session?.inferredOptionID == optB.id)
    }

    @Test func endClearsSession() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A")
        await monitor.start(destinationTitle: "Work", candidateOptions: [optA], at: Self.t0)
        await monitor.end()
        let session = await monitor.currentSession()
        #expect(session == nil)
    }

    @Test func tickNoOpsBeforeSessionStart() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A")
        let session = await monitor.tick(
            userPosition: nil,
            candidateOptions: [optA],
            distributions: [optA.id: distribution(p80: 1500)],
            now: Self.t0
        )
        #expect(session == nil)
    }

    @Test func phasePromotionWhenUserNearBoarding() async {
        let monitor = ActiveTripMonitor()
        let optA = option("A", boardingLat: 41.9, boardingLon: -87.65)
        await monitor.start(destinationTitle: "Work", candidateOptions: [optA], at: Self.t0)
        let session = await monitor.tick(
            userPosition: PlannerCoordinate(latitude: 41.9, longitude: -87.65),
            candidateOptions: [optA],
            distributions: [optA.id: distribution(p80: 1500)],
            now: Self.t0.addingTimeInterval(60)
        )
        #expect(session?.phase == .waitingForVehicle)
    }
}
