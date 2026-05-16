import Foundation
import Testing
@testable import TransitCache
@testable import TransitDomain
@testable import TransitModels

@Suite("DepartureLadderBuilder")
struct DepartureLadderBuilderTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let clock = FakeClock(Self.t0)
    private let walkingFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval = { _, _ in 240 }

    private func liveDepartures(_ minutesAhead: [Double]) -> [LiveDeparture] {
        minutesAhead.map { LiveDeparture(arrivalAt: Self.t0.addingTimeInterval($0 * 60)) }
    }

    private func candidate(
        title: String = "Red Line — Belmont",
        liveDepartures: [LiveDeparture],
        scheduleHeadwaySeconds: TimeInterval? = 480,
        feedState: FeedState = .fresh
    ) -> LadderCandidateSpec {
        LadderCandidateSpec(
            title: title,
            mode: .ctaTrain,
            routeIdentifier: "Red",
            direction: "Howard",
            boardingPoint: .station(systemRef: "40360", name: "Belmont", lineHint: "Red"),
            alightingPoint: .station(systemRef: "40330", name: "Roosevelt", lineHint: "Red"),
            inVehicleSeconds: 1320,
            inVehicleSigmaSeconds: 120,
            finalMileSeconds: 540,
            finalMileSigmaSeconds: 30,
            scheduleHeadwaySeconds: scheduleHeadwaySeconds,
            liveDepartures: liveDepartures,
            feedState: feedState
        )
    }

    @Test func singleCandidateProducesOrderedRows() {
        let builder = DepartureLadderBuilder()
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23, 31, 39]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(ladder.rows.count == 5)
        let leaveBys = ladder.rows.map { $0.leaveByAt }
        #expect(leaveBys == leaveBys.sorted())
    }

    @Test func dedupeCollapsesNearIdenticalLeaveBys() {
        let builder = DepartureLadderBuilder(dedupeWindowSeconds: 120)
        let candidates = [
            candidate(title: "Red A", liveDepartures: liveDepartures([7, 14, 21])),
            candidate(title: "Red B", liveDepartures: liveDepartures([7.5, 14.5, 21.5]))
        ]
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: candidates,
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(ladder.rows.count <= 3)
    }

    @Test func topRowsCappedAtMaxRows() {
        let builder = DepartureLadderBuilder(maxRows: 3)
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([5, 12, 19, 26, 33, 40, 47]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(ladder.rows.count == 3)
    }

    @Test func cliffDetectedWhenArrivalGapExceedsThreshold() {
        let builder = DepartureLadderBuilder(cliffThresholdSeconds: 8 * 60)
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 14, 35, 42]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(ladder.nextCliffAt != nil)
        #expect(ladder.headline != nil)
        #expect(ladder.headline?.contains("jumps") == true)
    }

    @Test func noCliffOnUniformHeadways() {
        let builder = DepartureLadderBuilder(cliffThresholdSeconds: 8 * 60)
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 14, 21, 28, 35]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(ladder.nextCliffAt == nil)
        #expect(ladder.headline == nil)
    }

    @Test func staleFeedDowngradesRiskLabel() {
        let builder = DepartureLadderBuilder()
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23]), feedState: .stale)],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        for row in ladder.rows {
            #expect(row.risk == .feedUnreliable)
        }
        #expect(ladder.lineHealth.first?.state == .feedStale)
    }

    @Test func missCostPopulatedForAllButLastRow() {
        let builder = DepartureLadderBuilder(maxRows: 4)
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23, 31]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let prefix = ladder.rows.dropLast()
        for row in prefix {
            #expect(row.missCostSeconds != nil)
            #expect((row.missCostSeconds ?? 0) > 0)
        }
        #expect(ladder.rows.last?.missCostSeconds == nil)
    }

    @Test func deterministicOutputForFixedInputs() {
        let builder = DepartureLadderBuilder()
        let runA = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23, 31, 39]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let runB = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23, 31, 39]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(runA.rows.map { $0.leaveByAt } == runB.rows.map { $0.leaveByAt })
        #expect(runA.rows.map { $0.totalDuration } == runB.rows.map { $0.totalDuration })
    }
}
