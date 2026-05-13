import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("CommutePlanner")
struct CommutePlannerTests {
    @Test func atHomePrefersToWork() {
        let planner = CommutePlanner()
        let preferences = [
            TrainPreference(mapId: 1, stopId: nil, stationName: "A", line: .red,
                            directionLabel: "Loop", direction: .toWork),
            TrainPreference(mapId: 2, stopId: nil, stationName: "B", line: .red,
                            directionLabel: "Home", direction: .toHome),
        ]
        let pick = planner.primaryTrain(from: preferences, context: .atHome)
        #expect(pick?.direction == .toWork)
    }

    @Test func atWorkPrefersToHome() {
        let planner = CommutePlanner()
        let preferences = [
            TrainPreference(mapId: 1, stopId: nil, stationName: "A", line: .red,
                            directionLabel: "Loop", direction: .toWork),
            TrainPreference(mapId: 2, stopId: nil, stationName: "B", line: .red,
                            directionLabel: "Home", direction: .toHome),
        ]
        let pick = planner.primaryTrain(from: preferences, context: .atWork)
        #expect(pick?.direction == .toHome)
    }

    @Test func unknownContextFallsBackToHourOfDay_morning() {
        let morning = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 5, day: 13, hour: 8))!
        let planner = CommutePlanner(clock: FakeClock(morning))
        let preferences = [
            TrainPreference(mapId: 1, stopId: nil, stationName: "A", line: .red,
                            directionLabel: "Loop", direction: .toWork),
            TrainPreference(mapId: 2, stopId: nil, stationName: "B", line: .red,
                            directionLabel: "Home", direction: .toHome),
        ]
        let pick = planner.primaryTrain(from: preferences, context: .unknown)
        #expect(pick?.direction == .toWork)
    }

    @Test func unknownContextFallsBackToHourOfDay_evening() {
        let evening = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 5, day: 13, hour: 18))!
        let planner = CommutePlanner(clock: FakeClock(evening))
        let preferences = [
            TrainPreference(mapId: 1, stopId: nil, stationName: "A", line: .red,
                            directionLabel: "Loop", direction: .toWork),
            TrainPreference(mapId: 2, stopId: nil, stationName: "B", line: .red,
                            directionLabel: "Home", direction: .toHome),
        ]
        let pick = planner.primaryTrain(from: preferences, context: .unknown)
        #expect(pick?.direction == .toHome)
    }
}
