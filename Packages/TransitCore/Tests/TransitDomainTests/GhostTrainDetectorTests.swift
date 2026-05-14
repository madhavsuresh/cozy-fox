import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("GhostTrainDetector")
struct GhostTrainDetectorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exactFreshVehicleMatchVerifiesArrival() {
        let arrival = makeArrival(
            runNumber: "418",
            predictedAt: now.addingTimeInterval(-90),
            arrivalAt: now.addingTimeInterval(60),
            isScheduled: true
        )
        let vehicle = VehiclePosition(
            id: "418",
            mode: .train,
            route: LineColor.red.rawValue,
            latitude: 41.0,
            longitude: -87.0,
            observedAt: now.addingTimeInterval(-30)
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [vehicle],
            now: now
        )

        #expect(assessment.status == .live)
        #expect(assessment.ghostScore == 0)
        #expect(assessment.matchingVehicleId == "418")
    }

    @Test func scheduledOnlyImminentArrivalWithoutVehicleIsLikelyGhost() {
        let arrival = makeArrival(
            predictedAt: now.addingTimeInterval(-60),
            arrivalAt: now.addingTimeInterval(75),
            isScheduled: true
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [],
            now: now
        )

        #expect(assessment.status == .likelyGhost)
        #expect(assessment.ghostScore >= 0.78)
    }

    @Test func scheduledOnlyDistantArrivalIsNotFlaggedForAttention() {
        let arrival = makeArrival(
            predictedAt: now.addingTimeInterval(-60),
            arrivalAt: now.addingTimeInterval(15 * 60),
            isScheduled: true
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [],
            now: now
        )

        #expect(assessment.status == .scheduledOnly)
        #expect(!assessment.needsRiderAttention)
    }

    @Test func freshRealtimePredictionIsLiveWithoutVehicleFallback() {
        let arrival = makeArrival(
            predictedAt: now.addingTimeInterval(-45),
            arrivalAt: now.addingTimeInterval(4 * 60),
            isScheduled: false
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [],
            now: now
        )

        #expect(assessment.status == .live)
        #expect(!assessment.needsRiderAttention)
    }

    @Test func stalePredictionWithoutPositionsReportsFeedStale() {
        let arrival = makeArrival(
            predictedAt: now.addingTimeInterval(-8 * 60),
            arrivalAt: now.addingTimeInterval(60),
            isScheduled: false
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [],
            now: now
        )

        #expect(assessment.status == .staleFeed)
        #expect(assessment.needsRiderAttention)
    }

    @Test func freshCacheFetchDoesNotHideStalePredictionTimestamp() {
        let arrival = makeArrival(
            predictedAt: now.addingTimeInterval(-8 * 60),
            arrivalAt: now.addingTimeInterval(60),
            isScheduled: false
        )

        let assessment = GhostTrainDetector().assessment(
            for: arrival,
            vehiclePositions: [],
            arrivalsFetchedAt: now,
            now: now
        )

        #expect(assessment.status == .staleFeed)
    }

    private func makeArrival(
        runNumber: String = "418",
        predictedAt: Date,
        arrivalAt: Date,
        isScheduled: Bool
    ) -> Arrival {
        Arrival(
            id: "\(runNumber)-30074-\(arrivalAt.timeIntervalSince1970)",
            line: .red,
            runNumber: runNumber,
            destinationName: "95th/Dan Ryan",
            stationId: 40380,
            stationName: "Clark/Division",
            stopId: 30074,
            directionCode: "1",
            predictedAt: predictedAt,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: isScheduled
        )
    }
}
