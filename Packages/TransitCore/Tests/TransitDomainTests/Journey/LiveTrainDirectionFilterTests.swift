import Foundation
import Testing
@testable import TransitCache
@testable import TransitDomain
@testable import TransitModels

@Suite("liveTrainDeparturesTowardAlighting")
struct LiveTrainDirectionFilterTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let boarding = LStation(
        id: 40330, name: "Chicago/State", latitude: 41.896, longitude: -87.628, servedLines: [.red]
    )
    private let northAlighting = LStation(
        id: 40900, name: "Howard", latitude: 42.019, longitude: -87.673, servedLines: [.red]
    )
    private let southTerminus = LStation(
        id: 40450, name: "95th/Dan Ryan", latitude: 41.722, longitude: -87.624, servedLines: [.red]
    )
    private var catalog: [LStation] { [boarding, northAlighting, southTerminus] }

    private func arrival(destinationName: String, minutesAhead: Double, directionCode: String = "1") -> Arrival {
        Arrival(
            id: "\(destinationName)-\(minutesAhead)",
            line: .red,
            runNumber: "R",
            destinationName: destinationName,
            stationId: boarding.id,
            stationName: boarding.name,
            stopId: 1,
            directionCode: directionCode,
            predictedAt: Self.t0,
            arrivalAt: Self.t0.addingTimeInterval(minutesAhead * 60),
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    @Test func keepsNorthboundDropsSouthboundForNorthAlighting() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(destinationName: "Howard", minutesAhead: 5),
                arrival(destinationName: "95th/Dan Ryan", minutesAhead: 7),
                arrival(destinationName: "Howard", minutesAhead: 13),
                arrival(destinationName: "95th/Dan Ryan", minutesAhead: 15)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let northbound = adapter.liveTrainDeparturesTowardAlighting(
            from: snapshot,
            line: .red,
            boardingStation: boarding,
            alightingStation: northAlighting,
            catalog: catalog,
            now: Self.t0
        )
        #expect(northbound.count == 2)
    }

    @Test func keepsSouthboundForSouthAlighting() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(destinationName: "Howard", minutesAhead: 5),
                arrival(destinationName: "95th/Dan Ryan", minutesAhead: 7)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let southbound = adapter.liveTrainDeparturesTowardAlighting(
            from: snapshot,
            line: .red,
            boardingStation: boarding,
            alightingStation: southTerminus,
            catalog: catalog,
            now: Self.t0
        )
        #expect(southbound.count == 1)
    }

    @Test func keepsArrivalsWithUnknownDestinationName() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(destinationName: "Loop", minutesAhead: 5),
                arrival(destinationName: "Howard", minutesAhead: 7),
                arrival(destinationName: "95th/Dan Ryan", minutesAhead: 9)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveTrainDeparturesTowardAlighting(
            from: snapshot,
            line: .red,
            boardingStation: boarding,
            alightingStation: northAlighting,
            catalog: catalog,
            now: Self.t0
        )
        #expect(result.count == 2)
    }

    @Test func dropsArrivalsAtOtherStationsAndOtherLines() {
        let otherStation = LStation(
            id: 99999, name: "Other", latitude: 41.5, longitude: -87.6, servedLines: [.red]
        )
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(destinationName: "Howard", minutesAhead: 5),
                Arrival(
                    id: "elsewhere",
                    line: .red,
                    runNumber: "R",
                    destinationName: "Howard",
                    stationId: otherStation.id,
                    stationName: otherStation.name,
                    stopId: 1,
                    directionCode: "1",
                    predictedAt: Self.t0,
                    arrivalAt: Self.t0.addingTimeInterval(8 * 60),
                    isApproaching: false,
                    isDelayed: false,
                    isFault: false,
                    isScheduled: false
                ),
                Arrival(
                    id: "blue",
                    line: .blue,
                    runNumber: "B",
                    destinationName: "Howard",
                    stationId: boarding.id,
                    stationName: boarding.name,
                    stopId: 1,
                    directionCode: "1",
                    predictedAt: Self.t0,
                    arrivalAt: Self.t0.addingTimeInterval(6 * 60),
                    isApproaching: false,
                    isDelayed: false,
                    isFault: false,
                    isScheduled: false
                )
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveTrainDeparturesTowardAlighting(
            from: snapshot,
            line: .red,
            boardingStation: boarding,
            alightingStation: northAlighting,
            catalog: catalog + [otherStation],
            now: Self.t0
        )
        #expect(result.count == 1)
    }

    @Test func dropsFaultRowsAndOldArrivals() {
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(destinationName: "Howard", minutesAhead: 5),
                Arrival(
                    id: "fault",
                    line: .red,
                    runNumber: "R",
                    destinationName: "Howard",
                    stationId: boarding.id,
                    stationName: boarding.name,
                    stopId: 1,
                    directionCode: "1",
                    predictedAt: Self.t0,
                    arrivalAt: Self.t0.addingTimeInterval(7 * 60),
                    isApproaching: false,
                    isDelayed: false,
                    isFault: true,
                    isScheduled: false
                ),
                arrival(destinationName: "Howard", minutesAhead: -10)
            ],
            trainsFetchedAt: Self.t0
        )
        let adapter = DepartureLadderSnapshotAdapter()
        let result = adapter.liveTrainDeparturesTowardAlighting(
            from: snapshot,
            line: .red,
            boardingStation: boarding,
            alightingStation: northAlighting,
            catalog: catalog,
            now: Self.t0
        )
        #expect(result.count == 1)
    }
}
