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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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
            destinationPoint: .anchor(.work),
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

    @Test func multiLegCandidateProducesTransferAnnotatedRow() {
        let builder = DepartureLadderBuilder()
        let transferDepartures = liveDepartures([15, 22, 29, 36])
        let transfer = LadderTransferLeg(
            transferWalkSeconds: 180,
            transferWalkSigmaSeconds: 30,
            nextMode: .ctaTrain,
            nextRouteIdentifier: "P",
            nextBoardingPoint: .station(systemRef: "L:40900", name: "Howard", lineHint: "P"),
            nextAlightingPoint: .station(systemRef: "L:41050", name: "Davis", lineHint: "P"),
            nextInVehicleSeconds: 540,
            nextInVehicleSigmaSeconds: 60,
            nextScheduleHeadwaySeconds: 600,
            nextLiveDepartures: transferDepartures,
            nextFeedState: .fresh
        )
        let candidate = candidate(
            title: "Red Line — Belmont",
            liveDepartures: liveDepartures([7, 14, 21, 28])
        )
        let withTransfer = LadderCandidateSpec(
            title: candidate.title,
            mode: candidate.mode,
            routeIdentifier: candidate.routeIdentifier,
            direction: candidate.direction,
            boardingPoint: candidate.boardingPoint,
            alightingPoint: .station(systemRef: "L:40900", name: "Howard", lineHint: "Red"),
            inVehicleSeconds: candidate.inVehicleSeconds,
            inVehicleSigmaSeconds: candidate.inVehicleSigmaSeconds,
            finalMileSeconds: candidate.finalMileSeconds,
            finalMileSigmaSeconds: candidate.finalMileSigmaSeconds,
            scheduleHeadwaySeconds: candidate.scheduleHeadwaySeconds,
            liveDepartures: candidate.liveDepartures,
            feedState: candidate.feedState,
            transfer: transfer
        )
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [withTransfer],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        #expect(!ladder.rows.isEmpty)
        #expect(ladder.rows.allSatisfy { $0.primaryLabel.contains("→") })
        #expect(ladder.lineHealth.count == 2)
    }

    @Test func rowsCarryWalkRideWalkLegsForSingleLegCandidate() {
        let builder = DepartureLadderBuilder()
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        guard let first = ladder.rows.first else {
            #expect(Bool(false), "expected at least one row")
            return
        }
        #expect(first.legs.count == 3)
        #expect(first.legs[0].mode == .walk)
        #expect(first.legs[1].mode == .ctaTrain)
        #expect(first.legs[2].mode == .walk)
        // Per-leg arrivals must be non-decreasing.
        for i in 1..<first.legs.count {
            #expect(first.legs[i].arrivalMean >= first.legs[i - 1].arrivalMean)
        }
    }

    @Test func rowCarriesBoardingTimeMatchingLiveDeparture() {
        // The card surfaces "Board HH:MM" so the rider can sanity-check the
        // row against the live-departures board on the platform. Pin the
        // contract: a row's boardingAt is the same wall-clock time that
        // showed up in the live departures feed.
        let builder = DepartureLadderBuilder()
        let departures = liveDepartures([7, 15, 23])
        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: departures)],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let boardingTimes = ladder.rows.compactMap(\.boardingAt)
        #expect(boardingTimes == departures.map(\.arrivalAt))
    }

    @Test func bikeBoardingShortensLeaveByVsWalk() {
        // Spec is single-leg + same departure schedule. The only difference is
        // the boarding leg: walking baseline at 240s vs biking at 90s. The
        // bike row should let the rider leave later for the same departure.
        let builder = DepartureLadderBuilder()
        let walkCandidate = candidate(liveDepartures: liveDepartures([10, 18, 26]))
        let bikeCandidate = LadderCandidateSpec(
            title: walkCandidate.title,
            mode: walkCandidate.mode,
            routeIdentifier: walkCandidate.routeIdentifier,
            direction: walkCandidate.direction,
            boardingPoint: walkCandidate.boardingPoint,
            alightingPoint: walkCandidate.alightingPoint,
            inVehicleSeconds: walkCandidate.inVehicleSeconds,
            inVehicleSigmaSeconds: walkCandidate.inVehicleSigmaSeconds,
            boardingMode: .divvyClassic,
            finalMileSeconds: walkCandidate.finalMileSeconds,
            finalMileSigmaSeconds: walkCandidate.finalMileSigmaSeconds,
            scheduleHeadwaySeconds: walkCandidate.scheduleHeadwaySeconds,
            liveDepartures: walkCandidate.liveDepartures,
            feedState: walkCandidate.feedState
        )
        let bikingFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval = { _, _ in 90 }
        let walkLadder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [walkCandidate],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let bikeLadder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [bikeCandidate],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: bikingFetcher,
            clock: clock
        )
        guard let walkRow = walkLadder.rows.first, let bikeRow = bikeLadder.rows.first else {
            #expect(Bool(false), "expected at least one row in each ladder")
            return
        }
        #expect(bikeRow.leaveByAt > walkRow.leaveByAt)
        #expect(bikeRow.legs.first?.mode == .divvyClassic)
        #expect(walkRow.legs.first?.mode == .walk)
    }

    @Test func bikeFinalMileShortensArrivalVsWalk() {
        let builder = DepartureLadderBuilder()
        let walkCandidate = candidate(liveDepartures: liveDepartures([7, 15, 23]))
        let bikeCandidate = LadderCandidateSpec(
            title: walkCandidate.title,
            mode: walkCandidate.mode,
            routeIdentifier: walkCandidate.routeIdentifier,
            direction: walkCandidate.direction,
            boardingPoint: walkCandidate.boardingPoint,
            alightingPoint: walkCandidate.alightingPoint,
            inVehicleSeconds: walkCandidate.inVehicleSeconds,
            inVehicleSigmaSeconds: walkCandidate.inVehicleSigmaSeconds,
            finalMileSeconds: walkCandidate.finalMileSeconds * 0.4, // bike ≈ 40% of walk time
            finalMileSigmaSeconds: walkCandidate.finalMileSigmaSeconds,
            finalMileMode: .divvyClassic,
            scheduleHeadwaySeconds: walkCandidate.scheduleHeadwaySeconds,
            liveDepartures: walkCandidate.liveDepartures,
            feedState: walkCandidate.feedState
        )
        let walkLadder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [walkCandidate],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let bikeLadder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [bikeCandidate],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        guard let walkRow = walkLadder.rows.first, let bikeRow = bikeLadder.rows.first else {
            #expect(Bool(false), "expected at least one row in each ladder")
            return
        }
        #expect(bikeRow.arrivalAt.low < walkRow.arrivalAt.low)
        #expect(bikeRow.legs.last?.mode == .divvyClassic)
        #expect(walkRow.legs.last?.mode == .walk)
    }

    @Test func deterministicOutputForFixedInputs() {
        let builder = DepartureLadderBuilder()
        let runA = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
            snapshot: .empty,
            candidates: [candidate(liveDepartures: liveDepartures([7, 15, 23, 31, 39]))],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )
        let runB = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            destinationPoint: .anchor(.work),
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
