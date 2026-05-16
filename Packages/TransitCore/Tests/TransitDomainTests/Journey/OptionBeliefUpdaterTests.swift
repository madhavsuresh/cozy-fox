import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("OptionBeliefUpdater")
struct OptionBeliefUpdaterTests {
    private func option(boardingLat: Double, boardingLon: Double, title: String) -> JourneyOption {
        let leg = LegCandidate(
            mode: .walk,
            displayLabel: title,
            fromPoint: .anchor(.home),
            toPoint: .coordinate(latitude: boardingLat, longitude: boardingLon)
        )
        return JourneyOption(title: title, summary: title, slots: [.fixed(leg)])
    }

    @Test func nilUserPositionReturnsUniformPriorOverOptionSet() {
        let updater = OptionBeliefUpdater()
        let optA = option(boardingLat: 41.9, boardingLon: -87.65, title: "A")
        let optB = option(boardingLat: 42.0, boardingLon: -87.7, title: "B")
        let beliefs = updater.update(currentBeliefs: [:], userPosition: nil, options: [optA, optB])
        #expect(beliefs[optA.id] == 0.5)
        #expect(beliefs[optB.id] == 0.5)
    }

    @Test func userAtBoardingPointBoostsThatOption() {
        let updater = OptionBeliefUpdater(proximityScaleMeters: 200)
        let optA = option(boardingLat: 41.9, boardingLon: -87.65, title: "A")
        let optB = option(boardingLat: 42.0, boardingLon: -87.7, title: "B")
        let userAtA = PlannerCoordinate(latitude: 41.9, longitude: -87.65)
        let beliefs = updater.update(
            currentBeliefs: [optA.id: 0.5, optB.id: 0.5],
            userPosition: userAtA,
            options: [optA, optB]
        )
        #expect((beliefs[optA.id] ?? 0) > (beliefs[optB.id] ?? 0))
    }

    @Test func beliefsSumToOneWithUserPosition() {
        let updater = OptionBeliefUpdater()
        let optA = option(boardingLat: 41.9, boardingLon: -87.65, title: "A")
        let optB = option(boardingLat: 42.0, boardingLon: -87.7, title: "B")
        let beliefs = updater.update(
            currentBeliefs: [optA.id: 0.5, optB.id: 0.5],
            userPosition: PlannerCoordinate(latitude: 41.95, longitude: -87.67),
            options: [optA, optB]
        )
        #expect(abs(beliefs.values.reduce(0, +) - 1.0) < 0.001)
    }

    @Test func emptyOptionsReturnsEmptyBeliefs() {
        let updater = OptionBeliefUpdater()
        let beliefs = updater.update(currentBeliefs: [:], userPosition: nil, options: [])
        #expect(beliefs.isEmpty)
    }

    @Test func dropsStaleEntriesNotInCurrentOptions() {
        let updater = OptionBeliefUpdater()
        let optA = option(boardingLat: 41.9, boardingLon: -87.65, title: "A")
        let stale = UUID()
        let beliefs = updater.update(
            currentBeliefs: [optA.id: 0.5, stale: 0.5],
            userPosition: PlannerCoordinate(latitude: 41.9, longitude: -87.65),
            options: [optA]
        )
        #expect(beliefs[stale] == nil)
        #expect(beliefs.count == 1)
    }
}
