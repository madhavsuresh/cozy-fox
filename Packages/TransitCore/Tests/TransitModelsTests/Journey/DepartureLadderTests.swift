import Foundation
import Testing
@testable import TransitModels

@Suite("DepartureLadder value type")
struct DepartureLadderTests {
    private func row(at leaveBy: TimeInterval, arrivalLow: TimeInterval, arrivalHigh: TimeInterval) -> DepartureLadderRow {
        DepartureLadderRow(
            leaveByAt: Date(timeIntervalSinceReferenceDate: leaveBy),
            totalDuration: TimeDistributionSummary.analytic(mean: 30 * 60, standardDeviation: 60, confidence: 0.7),
            arrivalAt: DepartureLadderRow.ArrivalWindow(
                low: Date(timeIntervalSinceReferenceDate: arrivalLow),
                high: Date(timeIntervalSinceReferenceDate: arrivalHigh)
            ),
            primaryLabel: "Red Line",
            secondaryLabel: nil,
            risk: .goodWait,
            note: nil,
            catchProbability: 0.85,
            missCostSeconds: nil
        )
    }

    @Test func arrivalWindowOrdersLowAndHigh() {
        let window = DepartureLadderRow.ArrivalWindow(
            low: Date(timeIntervalSinceReferenceDate: 100),
            high: Date(timeIntervalSinceReferenceDate: 50)
        )
        #expect(window.low.timeIntervalSinceReferenceDate == 50)
        #expect(window.high.timeIntervalSinceReferenceDate == 100)
    }

    @Test func sortedByLeaveByOrders() {
        let ladder = DepartureLadder(
            destinationTitle: "Work",
            generatedAt: Date(timeIntervalSinceReferenceDate: 0),
            rows: [row(at: 300, arrivalLow: 1800, arrivalHigh: 2100),
                   row(at: 100, arrivalLow: 1600, arrivalHigh: 1900)]
        )
        let sorted = ladder.sortedByLeaveBy
        #expect(sorted.map { $0.leaveByAt.timeIntervalSinceReferenceDate } == [100, 300])
    }

    @Test func codableRoundTrip() throws {
        let ladder = DepartureLadder(
            destinationTitle: "Work",
            generatedAt: Date(timeIntervalSinceReferenceDate: 0),
            rows: [row(at: 100, arrivalLow: 1600, arrivalHigh: 1900)],
            headline: "You can wait 2 min.",
            nextCliffAt: Date(timeIntervalSinceReferenceDate: 200),
            lineHealth: [
                LineHealthSnapshot(route: "Red", state: .normal, confidence: 0.7, generatedAt: Date(timeIntervalSinceReferenceDate: 0))
            ]
        )
        let data = try JSONEncoder().encode(ladder)
        let decoded = try JSONDecoder().decode(DepartureLadder.self, from: data)
        #expect(decoded == ladder)
    }

    @Test func catchProbabilityClampedToUnitInterval() {
        let r = DepartureLadderRow(
            leaveByAt: .distantPast,
            totalDuration: .zero,
            arrivalAt: DepartureLadderRow.ArrivalWindow(low: .distantPast, high: .distantFuture),
            primaryLabel: "x",
            risk: .unknown,
            catchProbability: 2.5
        )
        #expect(r.catchProbability == 1.0)
    }
}
