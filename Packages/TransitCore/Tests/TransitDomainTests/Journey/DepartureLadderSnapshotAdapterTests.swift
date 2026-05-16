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

    @Test func liveBusDeparturesFilterByRouteStopAndDirection() {
        let snapshot = TransitSnapshot(
            busPredictions: [
                bus(id: "a", route: "22", stopId: 1, direction: "Northbound", minutesAhead: 4),
                bus(id: "b", route: "22", stopId: 1, direction: "Southbound", minutesAhead: 5),
                bus(id: "c", route: "22", stopId: 2, direction: "Northbound", minutesAhead: 6),
                bus(id: "d", route: "151", stopId: 1, direction: "Northbound", minutesAhead: 7)
            ],
            busesFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveBusDepartures(from: snapshot, route: "22", stopId: 1, directionLabel: "Northbound", now: Self.t0)
        #expect(result.count == 1)
    }

    @Test func liveMetraDeparturesFilterByRouteStationDirectionAndDropCanceled() {
        let snapshot = TransitSnapshot(
            metraPredictions: [
                metra(id: "a", route: "UP-N", station: "OGILVIE", directionId: 0, minutesAhead: 6),
                metra(id: "b", route: "UP-N", station: "OGILVIE", directionId: 1, minutesAhead: 8),
                metra(id: "c", route: "UP-N", station: "OGILVIE", directionId: 0, minutesAhead: 14, isCanceled: true)
            ],
            metraFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveMetraDepartures(from: snapshot, routeId: "UP-N", stationId: "OGILVIE", directionId: 0, now: Self.t0)
        #expect(result.count == 1)
    }

    @Test func liveIntercampusDeparturesFilterByStopAndDirection() {
        let snapshot = TransitSnapshot(
            intercampusArrivals: [
                ic(id: "a", direction: .northbound, stopId: "CHIC1", minutesAhead: 5),
                ic(id: "b", direction: .southbound, stopId: "CHIC1", minutesAhead: 7),
                ic(id: "c", direction: .northbound, stopId: "EVAN1", minutesAhead: 9)
            ],
            intercampusFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveIntercampusDepartures(from: snapshot, stopId: "CHIC1", direction: .northbound, now: Self.t0)
        #expect(result.count == 1)
    }

    private func bus(id: String, route: String, stopId: Int, direction: String, minutesAhead: Double) -> BusPrediction {
        BusPrediction(
            id: id, route: route, routeName: route, vehicleId: "v",
            stopId: stopId, stopName: "Stop", destinationName: "Dest",
            directionName: direction, generatedAt: Self.t0,
            arrivalAt: Self.t0.addingTimeInterval(minutesAhead * 60),
            isDelayed: false, isApproaching: false
        )
    }

    private func metra(id: String, route: String, station: String, directionId: Int, minutesAhead: Double, isCanceled: Bool = false) -> MetraPrediction {
        let when = Self.t0.addingTimeInterval(minutesAhead * 60)
        return MetraPrediction(
            id: id, routeId: route, routeShortName: route, tripId: "t\(id)",
            trainNumber: "N", stationId: station, stationName: station,
            destinationName: "Dest", directionId: directionId,
            generatedAt: Self.t0, scheduledAt: when, arrivalAt: when,
            delaySeconds: 0, isDelayed: false, isCanceled: isCanceled, isScheduled: false
        )
    }

    private func ic(id: String, direction: IntercampusDirection, stopId: String, minutesAhead: Double) -> IntercampusArrival {
        IntercampusArrival(
            id: id, routeId: "intercampus", direction: direction, tripId: "t\(id)",
            vehicleId: nil, vehicleLabel: nil, stopId: stopId, stopName: stopId,
            destinationName: "Dest", generatedAt: Self.t0,
            arrivalAt: Self.t0.addingTimeInterval(minutesAhead * 60),
            delaySeconds: 0, isDelayed: false
        )
    }
}
