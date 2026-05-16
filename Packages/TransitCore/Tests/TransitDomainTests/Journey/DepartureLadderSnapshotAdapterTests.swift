import Foundation
import Testing
@testable import TransitCache
@testable import TransitDomain
@testable import TransitModels

@Suite("DepartureLadderSnapshotAdapter")
struct DepartureLadderSnapshotAdapterTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func arrival(
        id: String,
        line: LineColor = .red,
        stationId: Int = 40360,
        directionCode: String = "5",
        minutesAhead: Double,
        isApproaching: Bool = false,
        isFault: Bool = false
    ) -> Arrival {
        Arrival(
            id: id,
            line: line,
            runNumber: "R\(id)",
            destinationName: "Howard",
            stationId: stationId,
            stationName: "Belmont",
            stopId: 1,
            directionCode: directionCode,
            predictedAt: Self.t0,
            arrivalAt: Self.t0.addingTimeInterval(minutesAhead * 60),
            isApproaching: isApproaching,
            isDelayed: false,
            isFault: isFault,
            isScheduled: false
        )
    }

    @Test func filtersByLineAndStation() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(id: "1", line: .red, stationId: 40360, minutesAhead: 5),
                arrival(id: "2", line: .blue, stationId: 40360, minutesAhead: 6),
                arrival(id: "3", line: .red, stationId: 99999, minutesAhead: 7),
                arrival(id: "4", line: .red, stationId: 40360, minutesAhead: 13)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let dep = adapter.liveTrainDepartures(from: snapshot, line: .red, stationId: 40360, now: Self.t0)
        #expect(dep.count == 2)
    }

    @Test func filtersByDirectionCodeWhenProvided() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(id: "1", directionCode: "5", minutesAhead: 5),
                arrival(id: "2", directionCode: "1", minutesAhead: 7)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let northbound = adapter.liveTrainDepartures(from: snapshot, line: .red, stationId: 40360, directionCode: "5", now: Self.t0)
        #expect(northbound.count == 1)
    }

    @Test func dropsFaultRows() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(id: "1", minutesAhead: 5),
                arrival(id: "2", minutesAhead: 7, isFault: true)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let dep = adapter.liveTrainDepartures(from: snapshot, line: .red, stationId: 40360, now: Self.t0)
        #expect(dep.count == 1)
    }

    @Test func freshFetchIsFresh() {
        let snapshot = TransitSnapshot(trainsFetchedAt: Self.t0)
        let adapter = DepartureLadderSnapshotAdapter()
        #expect(adapter.feedState(from: snapshot, now: Self.t0) == .fresh)
    }

    @Test func oldFetchIsStale() {
        let snapshot = TransitSnapshot(trainsFetchedAt: Self.t0)
        let adapter = DepartureLadderSnapshotAdapter()
        #expect(adapter.feedState(from: snapshot, now: Self.t0.addingTimeInterval(600)) == .stale)
    }

    @Test func missingFetchIsMissing() {
        let snapshot = TransitSnapshot()
        let adapter = DepartureLadderSnapshotAdapter()
        #expect(adapter.feedState(from: snapshot, now: Self.t0) == .missing)
    }
}
