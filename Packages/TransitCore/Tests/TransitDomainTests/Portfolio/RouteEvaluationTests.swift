import Foundation
import Testing
@testable import TransitDomain
import TransitModels

@Suite("RouteEvaluation primitives")
struct RouteEvaluationTests {
    @Test func imminentVehicleCasesPreserveAgencyNativeIDs() {
        let train = ImminentVehicle.train(runNumber: "401", stationID: 40380, line: .red)
        let bus = ImminentVehicle.bus(vehicleID: "1841", stopID: 1234, route: "22")
        let metra = ImminentVehicle.metra(tripID: "UPN_001", stationID: "DAVIS", route: "UP-N")
        let intercampus = ImminentVehicle.intercampus(
            tripID: "ICR_001",
            stopID: "evanston-davis",
            direction: .southbound
        )

        // Identities don't collapse across modes.
        #expect(Set([train, bus, metra, intercampus]).count == 4)
    }

    @Test func evaluationOfWalkingOnlyOptionHasNoImminentVehicle() {
        let optionID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let eval = RouteEvaluation(
            optionID: optionID,
            available: true,
            etaMedian: now.addingTimeInterval(600),
            etaStdDev: 0,
            pFailure: 0,
            transferCount: 0,
            nextActionDeadline: now,
            confidence: 1.0,
            imminentVehicle: nil,
            unavailableReason: nil
        )
        #expect(eval.id == optionID)
        #expect(eval.imminentVehicle == nil)
        #expect(eval.unavailableReason == nil)
        #expect(eval.available == true)
    }

    @Test func unavailableEvaluationCarriesReason() {
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let eval = RouteEvaluation(
            optionID: UUID(),
            available: false,
            etaMedian: now,
            etaStdDev: 0,
            pFailure: 1,
            transferCount: 0,
            nextActionDeadline: now,
            confidence: 0,
            imminentVehicle: nil,
            unavailableReason: .closedStation([40260])
        )
        #expect(eval.available == false)
        if case .closedStation(let ids) = eval.unavailableReason {
            #expect(ids == [40260])
        } else {
            Issue.record("expected .closedStation, got \(String(describing: eval.unavailableReason))")
        }
    }

    @Test func unavailableReasonsAreDistinct() {
        let reasons: Set<UnavailableReason> = [
            .noArrivalsInHorizon,
            .lastVehicleAlreadyPassed,
            .staleFeed,
            .userTooFar,
            .closedStation([1, 2]),
        ]
        #expect(reasons.count == 5)
    }
}
