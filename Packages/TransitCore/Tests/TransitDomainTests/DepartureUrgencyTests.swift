import Foundation
import Testing
@testable import TransitDomain

@Suite("DepartureUrgency")
struct DepartureUrgencyTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func returnsNilWhenWalkSecondsMissing() {
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(15 * 60),
            walkSeconds: nil,
            now: Self.now
        )
        #expect(urgency == nil)
    }

    @Test func returnsNilForNegativeWalk() {
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(15 * 60),
            walkSeconds: -10,
            now: Self.now
        )
        #expect(urgency == nil)
    }

    @Test func comfortableWhenLeaveByFarAway() {
        // Arrival in 20 min, walk 5 min → leave-by in 15 min. Beyond
        // the 10-min approaching threshold → comfortable.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(20 * 60),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .comfortable)
        #expect(urgency?.secondsUntilLeaveBy == TimeInterval(15 * 60))
    }

    @Test func approachingAtBoundary() {
        // Leave-by exactly 9:59 from now — inside approachingThreshold (10m).
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(14 * 60 + 59),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .approaching)
    }

    @Test func approachingExactlyAtThresholdGoesUpToComfortable() {
        // Leave-by exactly 10 min from now — boundary is exclusive.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(15 * 60),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .comfortable)
    }

    @Test func imminentInsideTwoMinutes() {
        // Arrival in 6 min, walk 5 min → leave-by in 1 min → imminent.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(6 * 60),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .imminent)
        #expect(urgency?.secondsUntilLeaveBy == TimeInterval(60))
    }

    @Test func imminentExactlyAtImminentThresholdGoesUp() {
        // Leave-by exactly 2 min from now — boundary is exclusive.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(7 * 60),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .approaching)
    }

    @Test func missedWhenLeaveByPassed() {
        // Arrival in 3 min, walk 5 min → leave-by was 2 min ago.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(3 * 60),
            walkSeconds: 5 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .missed)
        #expect(urgency?.secondsUntilLeaveBy == TimeInterval(-2 * 60))
    }

    @Test func zeroWalkPutsLeaveByEqualToArrival() {
        // Walk = 0 → leave-by = arrival. 5 min away → approaching (5 < 10).
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(5 * 60),
            walkSeconds: 0,
            now: Self.now
        )
        #expect(urgency?.bucket == .approaching)
    }

    @Test func customThresholdsArrangeBoundaries() {
        // Same input, but caller sets a 5-min approaching threshold so a
        // 7-min leave-by lands comfortable instead of approaching.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(12 * 60),
            walkSeconds: 5 * 60,
            now: Self.now,
            approachingThreshold: 5 * 60
        )
        #expect(urgency?.bucket == .comfortable)
    }

    @Test func extendsAcrossLongWalks() {
        // 60-min walk to a Metra station, train in 80 min → leave-by in
        // 20 min → comfortable. Sanity check that nothing here clamps.
        let urgency = DepartureUrgency.from(
            arrivalAt: Self.now.addingTimeInterval(80 * 60),
            walkSeconds: 60 * 60,
            now: Self.now
        )
        #expect(urgency?.bucket == .comfortable)
        #expect(urgency?.secondsUntilLeaveBy == TimeInterval(20 * 60))
    }
}
