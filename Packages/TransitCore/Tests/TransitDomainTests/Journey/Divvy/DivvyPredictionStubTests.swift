import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("DivvyPredictionStub")
struct DivvyPredictionStubTests {
    @Test func returnsConfiguredProbabilities() async {
        let stub = DivvyPredictionStub(
            usableClassicProbability: 0.7,
            usableEbikeProbability: 0.4,
            dockProbability: 0.9,
            freeParkAllowed: true
        )
        let classicP = await stub.usableBikeProbability(stationId: "TA1", at: .distantPast, kind: .classic)
        let ebikeP = await stub.usableBikeProbability(stationId: "TA1", at: .distantPast, kind: .ebike)
        let dockP = await stub.dockOpenProbability(stationId: "TA2", at: .distantPast)
        let freePark = await stub.freeBikeParkingAllowed(near: PlannerCoordinate(latitude: 41.9, longitude: -87.65), at: .distantPast)
        #expect(classicP == 0.7)
        #expect(ebikeP == 0.4)
        #expect(dockP == 0.9)
        #expect(freePark == true)
    }

    @Test func probabilitiesClampedToUnitInterval() async {
        let stub = DivvyPredictionStub(
            usableClassicProbability: 2.0,
            usableEbikeProbability: -0.5,
            dockProbability: 1.5
        )
        let classicP = await stub.usableBikeProbability(stationId: "x", at: .distantPast, kind: .classic)
        let ebikeP = await stub.usableBikeProbability(stationId: "x", at: .distantPast, kind: .ebike)
        let dockP = await stub.dockOpenProbability(stationId: "x", at: .distantPast)
        #expect(classicP == 1.0)
        #expect(ebikeP == 0.0)
        #expect(dockP == 1.0)
    }

    @Test func rideDurationsReflectKind() async {
        let stub = DivvyPredictionStub(
            classicRideMean: 800,
            ebikeRideMean: 400
        )
        let classic = await stub.rideDurationSeconds(fromStationId: "a", toStationId: "b", at: .distantPast, kind: .classic)
        let ebike = await stub.rideDurationSeconds(fromStationId: "a", toStationId: "b", at: .distantPast, kind: .ebike)
        #expect(classic == 800)
        #expect(ebike == 400)
        #expect(ebike < classic)
    }
}
