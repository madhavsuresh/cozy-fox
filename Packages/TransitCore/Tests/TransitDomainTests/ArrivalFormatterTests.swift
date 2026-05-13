import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("ArrivalFormatter")
struct ArrivalFormatterTests {
    private func arrival(in seconds: TimeInterval, delayed: Bool = false, approaching: Bool = false) -> Arrival {
        Arrival(
            id: "x", line: .red, runNumber: "0",
            destinationName: "x", stationId: 0, stationName: "x",
            stopId: 0, directionCode: "1",
            predictedAt: .now, arrivalAt: .now.addingTimeInterval(seconds),
            isApproaching: approaching, isDelayed: delayed, isFault: false, isScheduled: false
        )
    }

    @Test func dueWhenOneMinute() {
        let label = ArrivalFormatter.label(for: arrival(in: 60))
        #expect(label == .due)
    }

    @Test func approachingWhenFlagged() {
        let label = ArrivalFormatter.label(for: arrival(in: 30, approaching: true))
        #expect(label == .approaching)
    }

    @Test func delayedTagged() {
        let label = ArrivalFormatter.label(for: arrival(in: 480, delayed: true))
        if case .delayed(let m) = label { #expect(m == 8) } else { Issue.record("expected .delayed") }
    }

    @Test func minutesRounded() {
        let label = ArrivalFormatter.label(for: arrival(in: 310))
        if case .minutes(let m) = label { #expect(m == 5) } else { Issue.record("expected .minutes") }
    }
}
