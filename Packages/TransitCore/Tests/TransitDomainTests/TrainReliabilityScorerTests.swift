import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("TrainReliabilityScorer")
struct TrainReliabilityScorerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Clark/Division station coordinates — real platform on the Red Line.
    private static let clarkDivision = (lat: 41.9036, lon: -87.6313)

    private func arrival(
        id: String = "418-40630-1",
        line: LineColor = .red,
        runNumber: String = "418",
        // 40630 is Clark/Division (real catalog id), so
        // `catalogedAssessments` resolves to the matching coords used by
        // the `clarkDivision` constant above.
        stationId: Int = 40630,
        stopId: Int = 30074,
        generatedAgo: TimeInterval = 20,
        etaSeconds: TimeInterval,
        isApproaching: Bool? = nil,
        isDelayed: Bool = false,
        isFault: Bool = false,
        isScheduled: Bool = false
    ) -> Arrival {
        Arrival(
            id: id,
            line: line,
            runNumber: runNumber,
            destinationName: "95th/Dan Ryan",
            stationId: stationId,
            stationName: "Clark/Division",
            stopId: stopId,
            directionCode: "1",
            predictedAt: Self.now.addingTimeInterval(-generatedAgo),
            arrivalAt: Self.now.addingTimeInterval(etaSeconds),
            isApproaching: isApproaching ?? (etaSeconds <= 60),
            isDelayed: isDelayed,
            isFault: isFault,
            isScheduled: isScheduled
        )
    }

    private func vehicle(
        runNumber: String = "418",
        line: LineColor = .red,
        nearby: Bool,
        observedAgo: TimeInterval = 25,
        nextStopId: Int? = nil
    ) -> VehiclePosition {
        let station = Self.clarkDivision
        // ~3 km north of the station when "not nearby" — trains move
        // faster than buses, so the far-distance threshold is higher
        // (1500m) and we need to be well past it to trigger.
        let coords: (Double, Double) = nearby
            ? (station.lat + 0.0008, station.lon)
            : (station.lat + 0.03, station.lon)
        return VehiclePosition(
            id: runNumber,
            mode: .train,
            route: line.rawValue,
            latitude: coords.0,
            longitude: coords.1,
            heading: 0,
            destinationName: "95th/Dan Ryan",
            nextStopId: nextStopId,
            observedAt: Self.now.addingTimeInterval(-observedAgo)
        )
    }

    @Test("Fresh vehicle near station with low ETA → high confidence")
    func freshVehicleNearStationIsHighConfidence() {
        let arr = arrival(etaSeconds: 60)
        let veh = vehicle(nearby: true, observedAgo: 15, nextStopId: 30074)

        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: veh,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.state == .highConfidence)
        #expect(result.isDisplayable)
        #expect(!result.needsMutedStyling)
        #expect(result.reasonCodes.contains(.vehicleFresh))
        #expect(result.reasonCodes.contains(.vehicleNearStationAtDue))
        #expect(result.reasonCodes.contains(.lineMatch))
        #expect(result.reasonCodes.contains(.nextStopMatchesArrival))
        #expect(result.reasonCodes.contains(.approachingFlag))
    }

    @Test("No matching run + DUE → ghost, do not display")
    func ghostArrivalWithImminentETAAbstains() {
        let arr = arrival(etaSeconds: 60)
        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: nil,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(!result.isDisplayable)
        #expect(result.reasonCodes.contains(.vehicleNotFound))
    }

    @Test("Fresh vehicle but far from station while CTA says DUE → abstain")
    func dueButVehicleFarFromStationAbstains() {
        let arr = arrival(etaSeconds: 60)
        let veh = vehicle(nearby: false, observedAgo: 10)

        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: veh,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(!result.isDisplayable)
        #expect(result.reasonCodes.contains(.dueButVehicleNotNearStation))
    }

    @Test("isApp without a matching vehicle is the train-specific ghost signature")
    func approachingFlagWithoutVehicleIsUnreliable() {
        // 4 minutes out — outside the abstain window — but CTA insists
        // the train is approaching while the positions feed shows
        // nothing. Should land in lowConfidence/unreliable and carry
        // the APP_BUT_NO_VEHICLE reason code.
        let arr = arrival(etaSeconds: 4 * 60, isApproaching: true)
        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: nil,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.isDisplayable)
        #expect(result.state == .lowConfidence || result.state == .unreliable)
        #expect(result.reasonCodes.contains(.approachingButNoVehicle))
        #expect(result.reasonCodes.contains(.vehicleNotFound))
    }

    @Test("isFault drops a no-vehicle arrival from low-confidence to unreliable")
    func faultFlagDowngradesConfidence() {
        // 8 minutes out, no vehicle. Without isFault that's a
        // lowConfidence row. With isFault it should drop into
        // unreliable while still being visible.
        let plain = arrival(id: "x-1", etaSeconds: 8 * 60)
        let faulty = arrival(id: "x-2", etaSeconds: 8 * 60, isFault: true)

        let plainResult = TrainReliabilityScorer().assessment(
            for: plain,
            vehicle: nil,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )
        let faultyResult = TrainReliabilityScorer().assessment(
            for: faulty,
            vehicle: nil,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(plainResult.state == .lowConfidence)
        #expect(faultyResult.state == .unreliable)
        #expect(faultyResult.reasonCodes.contains(.faultFlagged))
    }

    @Test("isSch with no vehicle still renders but at low confidence")
    func scheduledOnlyStaysVisibleAtLowConfidence() {
        let arr = arrival(etaSeconds: 12 * 60, isScheduled: true)
        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: nil,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.isDisplayable)
        #expect(result.reasonCodes.contains(.scheduledOnly))
        #expect(result.reasonCodes.contains(.vehicleNotFound))
        #expect(result.state == .lowConfidence || result.state == .unreliable)
    }

    @Test("Past-due arrival is always doNotDisplay")
    func pastDueIsAbstain() {
        let arr = arrival(id: "past-1", etaSeconds: -120)
        let result = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: vehicle(nearby: true),
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes == [.arrivalAlreadyPassed])
    }

    @Test("Major service alert on line downgrades, doesn't hide")
    func majorAlertSoftDowngrade() {
        let arr = arrival(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 20)
        let alert = ServiceAlert(
            id: "alert-1",
            headline: "Red Line rerouted around tower closure",
            shortDescription: "Operations affected",
            severity: .high,
            impactedRoutes: [],
            impactedLineColors: [.red],
            beginsAt: Self.now.addingTimeInterval(-3600),
            endsAt: Self.now.addingTimeInterval(3600),
            isMajor: true
        )

        let withAlert = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: veh,
            stationLocation: Self.clarkDivision,
            alerts: [alert],
            now: Self.now
        )
        let withoutAlert = TrainReliabilityScorer().assessment(
            for: arr,
            vehicle: veh,
            stationLocation: Self.clarkDivision,
            now: Self.now
        )

        #expect(withAlert.reasonCodes.contains(.majorAlertOnLine))
        #expect(!withoutAlert.reasonCodes.contains(.majorAlertOnLine))
        #expect(withAlert.score < withoutAlert.score)
        // Soft downgrade — must not hide a tracked nearby arrival.
        #expect(withAlert.isDisplayable)
    }

    @Test("Run-number matching is case- and whitespace-insensitive")
    func runNumberMatchingNormalizes() {
        let arr = arrival(runNumber: " 418 ", etaSeconds: 4 * 60)
        let veh = vehicle(runNumber: "418", nearby: true, observedAgo: 10)

        let result = TrainReliabilityScorer().catalogedAssessments(
            for: [arr],
            vehiclePositions: [veh],
            now: Self.now
        )[arr.id]

        let reasons = result?.reasonCodes ?? []
        #expect(reasons.contains(TrainArrivalReliability.ReasonCode.runNumberMatch))
        #expect(!reasons.contains(TrainArrivalReliability.ReasonCode.vehicleNotFound))
    }

    @Test("displayableArrivals drops abstained rows")
    func displayableHelperDropsAbstained() {
        let liveArr = arrival(id: "live-1", runNumber: "418", etaSeconds: 60)
        let ghostArr = arrival(id: "ghost-1", runNumber: "999", etaSeconds: 60)
        let veh = vehicle(runNumber: "418", nearby: true, observedAgo: 10)

        let displayable = TrainReliabilityScorer.displayableArrivals(
            from: [liveArr, ghostArr],
            vehiclePositions: [veh],
            now: Self.now
        )

        #expect(displayable.map(\.id).contains("live-1"))
        #expect(!displayable.map(\.id).contains("ghost-1"))
    }
}
