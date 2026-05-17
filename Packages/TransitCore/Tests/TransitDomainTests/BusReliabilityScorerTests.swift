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

    // MARK: - Pattern-aware scoring (phase 3a)

    private static let testPattern = BusPattern(
        id: 4042,
        route: "65",
        directionName: "Westbound",
        lengthFeet: 3200,
        detourId: nil,
        points: [
            BusPatternPoint(sequence: 1, latitude: 41.8919, longitude: -87.6182,
                            patternDistanceFeet: 0, kindRaw: "S",
                            stopId: 456, stopName: "Grand & McClurg"),
            BusPatternPoint(sequence: 2, latitude: 41.8919, longitude: -87.6203,
                            patternDistanceFeet: 580, kindRaw: "W",
                            stopId: nil, stopName: nil),
            BusPatternPoint(sequence: 3, latitude: 41.8919, longitude: -87.6225,
                            patternDistanceFeet: 1160, kindRaw: "S",
                            stopId: 457, stopName: "Grand & Columbus"),
            BusPatternPoint(sequence: 4, latitude: 41.8919, longitude: -87.6260,
                            patternDistanceFeet: 2050, kindRaw: "W",
                            stopId: nil, stopName: nil),
            BusPatternPoint(sequence: 5, latitude: 41.8919, longitude: -87.6300,
                            patternDistanceFeet: 3200, kindRaw: "S",
                            stopId: 458, stopName: "Grand & Michigan"),
        ]
    )

    /// Prediction for the middle stop (Grand & Columbus, stpid 457). pdist
    /// = 1160 ft on the test pattern; tests vary the vehicle's pdist
    /// relative to that.
    private func columbusPrediction(
        etaSeconds: TimeInterval,
        vehicleId: String = "1234"
    ) -> BusPrediction {
        BusPrediction(
            id: "65-457-\(Int(etaSeconds))",
            route: "65",
            routeName: "65 Grand",
            vehicleId: vehicleId,
            stopId: 457,
            stopName: "Grand & Columbus",
            destinationName: "Grand/Nordica",
            directionName: "Westbound",
            generatedAt: Self.now.addingTimeInterval(-15),
            arrivalAt: Self.now.addingTimeInterval(etaSeconds),
            isDelayed: false,
            isApproaching: etaSeconds <= 60
        )
    }

    private func vehicleOnPattern(
        patternDistance: Double,
        patternId: Int? = 4042,
        observedAgo: TimeInterval = 15
    ) -> VehiclePosition {
        // Lay vehicle at ~lat 41.8919, walking the longitude across the
        // pattern in proportion to its pdist (0 ft = -87.6182, 3200 ft =
        // -87.6300). Keeps the map-match honest.
        let fraction = min(max(patternDistance / 3200, 0), 1)
        let lon = -87.6182 + fraction * (-87.6300 - -87.6182)
        return VehiclePosition(
            id: "1234",
            mode: .bus,
            route: "65",
            latitude: 41.8919,
            longitude: lon,
            heading: 270,
            destinationName: "Grand/Nordica",
            nextStopId: nil,
            patternId: patternId,
            patternDistanceFeet: patternDistance,
            observedAt: Self.now.addingTimeInterval(-observedAgo)
        )
    }

    @Test("Pattern-aware: vehicle past the stop along pattern → abstain")
    func patternCrossedStopAbstains() {
        let pred = columbusPrediction(etaSeconds: 60)
        let veh = vehicleOnPattern(patternDistance: 2050)  // 890 ft past stop 457

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            patterns: [Self.testPattern],
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes.contains(.pdistCrossedStop))
        #expect(result.reasonCodes.contains(.patternMatch))
    }

    @Test("Pattern-aware: DUE but pdist says vehicle is still 1500 ft away → abstain")
    func patternDueButFarAbstains() {
        let pred = columbusPrediction(etaSeconds: 60)
        // Stop 457 is at pdist 1160; vehicle at -500 ft means 1660 ft remaining.
        let veh = vehicleOnPattern(patternDistance: -500 + 1160)
        // Easier to set explicitly:
        let vehExplicit = vehicleOnPattern(patternDistance: 0)  // 1160 ft upstream

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: vehExplicit,
            stopLocation: Self.grandAndMcClurg,
            patterns: [Self.testPattern],
            now: Self.now
        )

        _ = veh
        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes.contains(.dueButVehicleNotNearStop))
        #expect(result.reasonCodes.contains(.patternMatch))
        // The pattern path should NOT also trigger the haversine path.
        #expect(result.reasonCodes.filter { $0 == .dueButVehicleNotNearStop }.count == 1)
    }

    @Test("Pattern-aware: DUE and pdist within 800 ft → high confidence boost")
    func patternDueAndNearBoosts() {
        let pred = columbusPrediction(etaSeconds: 60)
        // Stop 457 at pdist 1160. Vehicle at 800 ft → 360 ft remaining.
        let veh = vehicleOnPattern(patternDistance: 800)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            patterns: [Self.testPattern],
            now: Self.now
        )

        #expect(result.isDisplayable)
        #expect(result.reasonCodes.contains(.vehicleNearStopAtDue))
        #expect(result.reasonCodes.contains(.patternMatch))
        #expect(result.state == .highConfidence)
    }

    @Test("Pattern-aware: GPS far off pattern downgrades reliability")
    func patternGpsOffDowngrades() {
        let pred = columbusPrediction(etaSeconds: 4 * 60)
        // pdist within range but GPS placed 1000 m north of the pattern.
        let off = VehiclePosition(
            id: "1234", mode: .bus, route: "65",
            latitude: 41.9009, longitude: -87.6225,
            heading: 270, destinationName: "Grand/Nordica",
            nextStopId: nil, patternId: 4042, patternDistanceFeet: 1000,
            observedAt: Self.now.addingTimeInterval(-15)
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: off,
            stopLocation: Self.grandAndMcClurg,
            patterns: [Self.testPattern],
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.gpsOffExpectedPattern))
    }

    @Test("No patterns loaded → falls back to haversine path")
    func noPatternsFallsBackToHaversine() {
        let pred = columbusPrediction(etaSeconds: 60)
        let veh = vehicleOnPattern(patternDistance: 800)

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            patterns: [],
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.patternMatch))
        // Haversine path uses meters threshold; still produces some
        // assessment — should not crash.
        _ = result.state
    }

    // MARK: - Stop-removed-by-detour abstain (phase 2b)

    @Test("Stop removed by active detour → abstain regardless of other evidence")
    func stopRemovedByDetourAbstains() {
        // Strong positive evidence otherwise — fresh vehicle right at the
        // stop — but the stop is removed by an active detour. The scorer
        // must still abstain so the rider doesn't wait for a bus that's
        // been routed around them.
        let pred = prediction(etaSeconds: 60)
        let veh = vehicle(nearby: true, observedAgo: 15)
        let detour = BusDetour(
            id: "DTR-9000", version: 1, isActive: true,
            summary: "Stop closed for construction",
            affected: [.init(route: "65", directionName: "Westbound")],
            beginsAt: Self.now.addingTimeInterval(-3600),
            endsAt: Self.now.addingTimeInterval(3600)
        )
        let stopState = BusStopDetourState(
            stopId: 456,
            addedByDetourIds: [],
            removedByDetourIds: ["DTR-9000"]
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [detour],
            stopDetourState: stopState,
            now: Self.now
        )

        #expect(result.state == .doNotDisplay)
        #expect(result.reasonCodes.contains(.stopRemovedByDetour))
    }

    @Test("Stop removed by an *inactive* detour → no abstain")
    func stopRemovedOnlyByInactiveDetourDoesNotAbstain() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 15)
        let inactive = BusDetour(
            id: "DTR-OLD", version: 1, isActive: false,
            summary: "Resolved yesterday", affected: [],
            beginsAt: nil, endsAt: nil
        )
        let stopState = BusStopDetourState(
            stopId: 456,
            addedByDetourIds: [],
            removedByDetourIds: ["DTR-OLD"]
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [inactive],
            stopDetourState: stopState,
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.stopRemovedByDetour))
        #expect(result.isDisplayable)
    }

    @Test("Stop in `addedByDetourIds` is not abstained")
    func stopAddedByDetourDoesNotAbstain() {
        let pred = prediction(etaSeconds: 4 * 60)
        let veh = vehicle(nearby: true, observedAgo: 15)
        let active = BusDetour(
            id: "DTR-ADD", version: 1, isActive: true, summary: "",
            affected: [], beginsAt: nil, endsAt: nil
        )
        let stopState = BusStopDetourState(
            stopId: 456,
            addedByDetourIds: ["DTR-ADD"],
            removedByDetourIds: []
        )

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            activeDetours: [active],
            stopDetourState: stopState,
            now: Self.now
        )

        #expect(!result.reasonCodes.contains(.stopRemovedByDetour))
        #expect(result.isDisplayable)
    }

    @Test("Patterns loaded but vehicle pid unknown → patternMismatch + haversine fallback")
    func patternMismatchFallsBack() {
        let pred = columbusPrediction(etaSeconds: 60)
        let veh = vehicleOnPattern(patternDistance: 800, patternId: 7777)  // unknown pid

        let result = BusReliabilityScorer().assessment(
            for: pred,
            vehicle: veh,
            stopLocation: Self.grandAndMcClurg,
            patterns: [Self.testPattern],
            now: Self.now
        )

        #expect(result.reasonCodes.contains(.patternMismatch))
        #expect(!result.reasonCodes.contains(.patternMatch))
    }
}
