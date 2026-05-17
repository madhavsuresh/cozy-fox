import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("CTA Bus Tracker decoder")
struct CTABusClientTests {
    @Test func decodesPredictionsAndDelayFlag() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getpredictions",
            data: Fixture.load("cta_bus_predictions")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let predictions = try await client.fetchPredictions(route: "22", stopId: 1234)

        #expect(predictions.count == 3)
        let first = try #require(predictions.first)
        #expect(first.route == "22")
        #expect(first.stopId == 1234)
        #expect(first.directionName == "Northbound")
        #expect(first.destinationName == "Howard")
        #expect(!first.isApproaching, "prdctdn 3 is more than 1 min away")
        #expect(!first.isDelayed)
        #expect(first.dynamicActionCode == 0, "explicit dyn=0 round-trips as zero, not nil")
        #expect(!first.hasNonStandardDynamicAction)
        #expect(!first.predictionCountdownIsUncertain)

        // Second row omits `dyn` entirely — should decode as nil and
        // count as standard.
        let second = predictions[1]
        #expect(second.dynamicActionCode == nil)
        #expect(!second.hasNonStandardDynamicAction)

        // Third row carries `prdctdn=DLY` plus a string-form `dyn=18`
        // (the layover code). Verifies both new signals decode and that
        // string-form ints behave like the vehicles feed.
        let third = predictions[2]
        #expect(third.predictionCountdownIsUncertain)
        #expect(third.isDelayed, "dly=true round-trips into isDelayed")
        #expect(third.dynamicActionCode == 18)
        #expect(third.hasNonStandardDynamicAction)
        #expect(!third.isApproaching, "DLY sentinel is not an approaching state")
    }

    @Test func decodesDetoursAndActiveFlag() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getdetours",
            data: Fixture.load("cta_bus_detours")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let detours = try await client.fetchDetours(routes: ["65", "22"])

        #expect(detours.count == 2)
        let active = try #require(detours.first { $0.id == "DTR-5621" })
        #expect(active.isActive)
        #expect(active.version == 3)
        #expect(active.affected.count == 2)
        #expect(active.affected.contains(.init(route: "65", directionName: "Westbound")))
        #expect(active.beginsAt != nil)
        #expect(active.endsAt != nil)
        // Affects helper respects route+direction case-insensitively.
        #expect(active.affects(route: "65", direction: "westbound", at: active.beginsAt!.addingTimeInterval(3600)))
        #expect(!active.affects(route: "22", direction: "Northbound", at: active.beginsAt!.addingTimeInterval(3600)))

        let lifted = try #require(detours.first { $0.id == "DTR-5500" })
        #expect(!lifted.isActive)
        #expect(!lifted.affects(route: "22", direction: "Northbound", at: Date()))
    }

    @Test func decodesPatternsAndOrdersPoints() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getpatterns",
            data: Fixture.load("cta_bus_patterns")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let patterns = try await client.fetchPatterns(routes: ["65"])

        #expect(patterns.count == 1)
        let pattern = try #require(patterns.first)
        #expect(pattern.id == 4042)
        #expect(pattern.route == "65")
        #expect(pattern.directionName == "Westbound")
        #expect(pattern.lengthFeet == 27410.5)
        #expect(pattern.detourId == nil)
        #expect(pattern.points.count == 5)
        // Points round-trip sorted by sequence.
        #expect(pattern.points.map(\.sequence) == [1, 2, 3, 4, 5])
        // Stop and waypoint distinction.
        #expect(pattern.points.first?.isStop == true)
        #expect(pattern.points[1].isStop == false)
        // Stop-by-id lookup.
        #expect(pattern.patternDistanceForStop(457) == 1160.0)
        #expect(pattern.patternDistanceForStop(99999) == nil)
    }

    @Test func decodesStopDetourStateFromV3GetStops() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v3/getstops",
            data: Fixture.load("cta_bus_stops_v3")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let states = try await client.fetchStopDetourStates(stopIds: [456, 999, 1000])

        #expect(states.count == 3)
        let removed = try #require(states.first { $0.stopId == 456 })
        #expect(removed.removedByDetourIds == ["DTR-5621"])
        #expect(removed.addedByDetourIds.isEmpty)
        // isRemovedBy with an active detour matching the id → true.
        let activeDtr = BusDetour(
            id: "DTR-5621", version: 1, isActive: true, summary: "",
            affected: [], beginsAt: nil, endsAt: nil
        )
        #expect(removed.isRemovedBy(activeDetours: [activeDtr]))

        // Same detour but inactive → not removed.
        let inactiveDtr = BusDetour(
            id: "DTR-5621", version: 1, isActive: false, summary: "",
            affected: [], beginsAt: nil, endsAt: nil
        )
        #expect(!removed.isRemovedBy(activeDetours: [inactiveDtr]))

        let added = try #require(states.first { $0.stopId == 999 })
        #expect(added.addedByDetourIds == ["DTR-5621"])
        #expect(added.removedByDetourIds.isEmpty)
        #expect(!added.isRemovedBy(activeDetours: [activeDtr]))

        let untouched = try #require(states.first { $0.stopId == 1000 })
        #expect(untouched.removedByDetourIds.isEmpty)
        #expect(untouched.addedByDetourIds.isEmpty)
    }

    @Test("Vehicles decoder accepts pid/pdist as either string or int")
    func decodesVehiclesWithFlexiblePidAndPdist() async throws {
        // Regression for the post-phase-3a bug where every imminent bus
        // prediction got hidden because the strict `Int?` declaration on
        // `pid` / `pdist` threw `typeMismatch` whenever CTA returned
        // them as JSON strings — wiping out the entire vehicle list
        // and forcing the scorer's `vehicleNotFound` abstain on every
        // DUE prediction.
        let stub = StubHTTPClient()
        await stub.register(
            path: "/bustime/api/v2/getvehicles",
            data: Fixture.load("cta_bus_vehicles")
        )
        let client = CTABusClient(http: stub) { "stub-key" }
        let vehicles = try await client.fetchVehicles(routes: ["65"])

        #expect(vehicles.count == 3)

        // Vehicle 1234 has pid/pdist as strings → must parse cleanly.
        let stringForm = try #require(vehicles.first { $0.id == "1234" })
        #expect(stringForm.patternId == 4042)
        #expect(stringForm.patternDistanceFeet == 1234)
        // Vehicle 5678 has pid/pdist as numbers → unchanged behavior.
        let intForm = try #require(vehicles.first { $0.id == "5678" })
        #expect(intForm.patternId == 4043)
        #expect(intForm.patternDistanceFeet == 9876)
        // Vehicle 9999 omits pid/pdist → nil, no failure.
        let absent = try #require(vehicles.first { $0.id == "9999" })
        #expect(absent.patternId == nil)
        #expect(absent.patternDistanceFeet == nil)
    }
}
