import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BusReliabilityScorer")
struct BusReliabilityScorerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let grandAndMcClurg = (lat: 41.8919, lon: -87.6182)

    private func prediction(
        id: String = "65-1234-1",
        route: String = "65",
        vehicleId: String = "1234",
        generatedAgo: TimeInterval = 15,
        etaSeconds: TimeInterval,
        delayed: Bool = false
    ) -> BusPrediction {
        BusPrediction(
            id: id,
            route: route,
            routeName: "65 Grand",
            vehicleId: vehicleId,
            stopId: 456,
            stopName: "Grand & McClurg",
            destinationName: "Grand/Nordica",
            directionName: "Westbound",
            generatedAt: Self.now.addingTimeInterval(-generatedAgo),
            arrivalAt: Self.now.addingTimeInterval(etaSeconds),
            isDelayed: delayed,
            isApproaching: etaSeconds <= 60
        )
    }

    private func vehicle(
        id: String = "1234",
        route: String = "65",
        nearby: Bool,
        observedAgo: TimeInterval = 20
    ) -> VehiclePosition {
        let stop = Self.grandAndMcClurg
        // ~1.5 km north of the stop when "not nearby".
        let coords: (Double, Double) = nearby
            ? (stop.lat + 0.0008, stop.lon)
            : (stop.lat + 0.015, stop.lon)
        return VehiclePosition(
            id: id,
            mode: .bus,
            route: route,
            latitude: coords.0,
            longitude: coords.1,
            observedAt: Self.now.addingTimeInterval(-observedAgo)
        )
    }

    @Test("Fresh vehicle near stop with low ETA → high confidence")
    func freshVehicleNearStopIsHighConfidence() {
        let pred = prediction(etaSeconds: 60)
        let veh = vehicle(nearby: true, observedAgo: 15)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.state == .highConfidence)
        #expect(result.isDisplayable)
        #expect(!result.needsMutedStyling)
        #expect(result.reasonCodes.contains(.vehicleFresh))
        #expect(result.reasonCodes.contains(.vehicleNearStopAtDue))
        #expect(result.reasonCodes.contains(.routeMatch))
    }

    @Test("No matching vehicle + DUE → ghost, do not display (the #65 case)")
    func ghostPredictionWithImminentETAAbstains() {
        let pred = prediction(etaSeconds: 60)
        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: nil,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(!result.isDisplayable)
        #expect(result.reasonCodes.contains(.vehicleNotFound))
    }

    @Test("No matching vehicle + far-out ETA → low/unreliable but still visible")
    func ghostPredictionWithFarETADoesNotAbstain() {
        let pred = prediction(etaSeconds: 8 * 60)
        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: nil,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.isDisplayable)
        #expect(result.state == .lowConfidence || result.state == .unreliable)
        #expect(result.reasonCodes.contains(.vehicleNotFound))
    }

    @Test("Fresh vehicle but far from stop while CTA says DUE → ghost, abstain")
    func dueButVehicleFarFromStopAbstains() {
        let pred = prediction(etaSeconds: 60)
        let veh = vehicle(nearby: false, observedAgo: 10)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes.contains(.dueButVehicleNotNearStop))
    }

    @Test("Stale vehicle observation → reliability downgraded")
    func staleVehicleObservationDowngrades() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 200) // > stale (120s)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.vehicleStale))
        #expect(result.state == .lowConfidence || result.state == .unreliable)
    }

    @Test("Vehicle on a different route → route mismatch downgrade")
    func routeMismatchDowngrades() {
        let pred = prediction(etaSeconds: 5 * 60)
        let veh = vehicle(id: "1234", route: "66", nearby: true, observedAgo: 10)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.routeMismatch))
        // Below mediumConfidence's 0.60 floor after the -0.20 hit.
        #expect(result.score < 0.60)
    }

    @Test("Stale prediction timestamp downgrades even with fresh vehicle")
    func stalePredictionDowngrades() {
        let pred = prediction(generatedAgo: 200, etaSeconds: 5 * 60)
        let veh = vehicle(nearby: true, observedAgo: 15)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.predictionStale))
    }

    @Test("Arrival in the past is hidden regardless of evidence")
    func pastArrivalIsDoNotDisplay() {
        let pred = prediction(etaSeconds: -120)
        let veh = vehicle(nearby: true, observedAgo: 10)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes.contains(.arrivalAlreadyPassed))
    }

    @Test("Delayed flag adds the reason code but does not abstain on its own")
    func delayedFlagAddsReasonOnly() {
        let pred = prediction(etaSeconds: 5 * 60, delayed: true)
        let veh = vehicle(nearby: true, observedAgo: 15)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.delayedFlagged))
        #expect(result.isDisplayable)
    }

    @Test("Missing stop location falls back gracefully")
    func missingStopLocationDoesNotCrash() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 10)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: nil,
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.stopLocationUnknown))
        // Without distance evidence we can't abstain on DUE-but-far, but the
        // other signals (route, freshness) still produce a reasonable score.
        #expect(result.isDisplayable)
    }

    @Test("assessments(for:) returns one entry per prediction keyed by id")
    func bulkAssessmentsKeyedById() {
        let p1 = prediction(id: "p1", vehicleId: "1234", etaSeconds: 60)
        let p2 = prediction(id: "p2", vehicleId: "9999", etaSeconds: 5 * 60)
        let veh = vehicle(id: "1234", nearby: true, observedAgo: 10)

        let map = BusReliabilityScorer().assessments(
            for: [p1, p2],
            vehicles: [veh],
            stopLocation: { _ in Self.grandAndMcClurg },
            now: Self.now
        )

        #expect(map.count == 2)
        #expect(map["p1"]?.state == .highConfidence)
        #expect(map["p2"]?.reasonCodes.contains(.vehicleNotFound) == true)
    }

    @Test("Active detour on the matching route+direction adds DETOUR_ACTIVE warn")
    func activeDetourAddsWarning() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 10)
        let detour = BusDetour(
            id: "DTR-1",
            version: 1,
            isActive: true,
            summary: "Grand & Wabash closure",
            affected: [.init(route: "65", directionName: "Westbound")],
            beginsAt: Self.now.addingTimeInterval(-3600),
            endsAt: Self.now.addingTimeInterval(3600)
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [detour],
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.detourActive))
        // Detour is just a warning — still displayable.
        #expect(result.isDisplayable)
    }

    @Test("Detour on a different direction does not affect the prediction")
    func detourOnDifferentDirectionDoesNotApply() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 10)
        let detour = BusDetour(
            id: "DTR-2",
            version: 1,
            isActive: true,
            summary: "Eastbound closure only",
            affected: [.init(route: "65", directionName: "Eastbound")],
            beginsAt: Self.now.addingTimeInterval(-3600),
            endsAt: Self.now.addingTimeInterval(3600)
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [detour],
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.detourActive))
    }

    @Test("Cancelled (inactive) detour does not add a warning")
    func inactiveDetourDoesNotApply() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 10)
        let detour = BusDetour(
            id: "DTR-3",
            version: 2,
            isActive: false,
            summary: "Detour already lifted",
            affected: [.init(route: "65", directionName: "Westbound")],
            beginsAt: Self.now.addingTimeInterval(-7200),
            endsAt: Self.now.addingTimeInterval(-3600)
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [detour],
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.detourActive))
    }

    @Test("Detour outside its begins-at/ends-at window does not apply")
    func detourOutsideTimeWindowDoesNotApply() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 10)
        let detour = BusDetour(
            id: "DTR-4",
            version: 1,
            isActive: true,
            summary: "Tomorrow morning rush only",
            affected: [.init(route: "65", directionName: "Westbound")],
            beginsAt: Self.now.addingTimeInterval(24 * 3600),
            endsAt: Self.now.addingTimeInterval(28 * 3600)
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [detour],
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.detourActive))
    }
}
