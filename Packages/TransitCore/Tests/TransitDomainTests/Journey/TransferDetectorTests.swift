import Foundation
import Testing
@testable import TransitCache
@testable import TransitDomain
@testable import TransitModels

@Suite("TransferDetector")
struct TransferDetectorTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let home: (lat: Double, lon: Double) = (41.895, -87.620)
    private let work: (lat: Double, lon: Double) = (42.045, -87.683)

    private let sourceBoarding = LStation(
        id: 40330, name: "Chicago/State", latitude: 41.896, longitude: -87.628, servedLines: [.red]
    )
    private let sourceTerminus = LStation(
        id: 40900, name: "Howard", latitude: 42.019, longitude: -87.673, servedLines: [.red, .purple]
    )
    private let purpleDestination = LStation(
        id: 41050, name: "Davis", latitude: 42.046, longitude: -87.683, servedLines: [.purple]
    )

    private var catalog: [LStation] {
        [sourceBoarding, sourceTerminus, purpleDestination]
    }

    private func arrival(line: LineColor, station: LStation, minutesAhead: Double, isFault: Bool = false) -> Arrival {
        Arrival(
            id: "\(line.rawValue)-\(station.id)-\(minutesAhead)",
            line: line,
            runNumber: "R",
            destinationName: "End",
            stationId: station.id,
            stationName: station.name,
            stopId: 1,
            directionCode: "5",
            predictedAt: Self.t0,
            arrivalAt: Self.t0.addingTimeInterval(minutesAhead * 60),
            isApproaching: false,
            isDelayed: false,
            isFault: isFault,
            isScheduled: false
        )
    }

    @Test func detectsTransferWhenSecondLineHasFreshArrivals() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(line: .red, station: sourceBoarding, minutesAhead: 5),
                arrival(line: .purple, station: sourceTerminus, minutesAhead: 12),
                arrival(line: .purple, station: purpleDestination, minutesAhead: 20)
            ],
            trainsFetchedAt: Self.t0,
            alertsFetchedAt: Self.t0
        )
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: sourceTerminus,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog
        )
        #expect(detected?.nextLine == .purple)
        #expect(detected?.intermediate.id == sourceTerminus.id)
        #expect(detected?.finalAlighting.id == purpleDestination.id)
    }

    @Test func skipsTransferWhenSecondLineHasNoArrivalsInSnapshot() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(line: .red, station: sourceBoarding, minutesAhead: 5)
            ],
            trainsFetchedAt: Self.t0
        )
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: sourceTerminus,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog
        )
        #expect(detected == nil)
    }

    @Test func skipsTransferWhenMajorAlertImpactsSecondLine() {
        let detector = TransferDetector()
        let purpleOutage = ServiceAlert(
            id: "purple-down",
            headline: "Purple Line Suspended",
            shortDescription: "No service.",
            severity: .high,
            impactedRoutes: [],
            impactedLineColors: [.purple],
            beginsAt: Self.t0.addingTimeInterval(-3600),
            endsAt: Self.t0.addingTimeInterval(3600),
            isMajor: true
        )
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(line: .red, station: sourceBoarding, minutesAhead: 5),
                arrival(line: .purple, station: sourceTerminus, minutesAhead: 12)
            ],
            activeAlerts: [purpleOutage],
            trainsFetchedAt: Self.t0
        )
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: sourceTerminus,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog
        )
        #expect(detected == nil)
    }

    @Test func skipsTransferWhenTrainsFeedNeverFetched() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot()
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: sourceTerminus,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog
        )
        #expect(detected == nil)
    }

    @Test func skipsTransferWhenStaleArrivalsAreFiltered() {
        let detector = TransferDetector(recentArrivalWindowSeconds: 5 * 60)
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(line: .red, station: sourceBoarding, minutesAhead: 5),
                arrival(line: .purple, station: sourceTerminus, minutesAhead: -60)
            ],
            trainsFetchedAt: Self.t0
        )
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: sourceTerminus,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog
        )
        #expect(detected == nil)
    }

    @Test func directAlightingCloseToWorkSkipsTransferEntirely() {
        let detector = TransferDetector()
        let nearbyAlighting = LStation(
            id: 40999, name: "Right next to work", latitude: 42.046, longitude: -87.683, servedLines: [.red]
        )
        let snapshot = TransitSnapshot(
            trainArrivals: [
                arrival(line: .red, station: sourceBoarding, minutesAhead: 5),
                arrival(line: .purple, station: sourceTerminus, minutesAhead: 12)
            ],
            trainsFetchedAt: Self.t0
        )
        let detected = detector.detect(
            sourceLine: .red,
            boardingStation: sourceBoarding,
            directAlighting: nearbyAlighting,
            home: home,
            work: work,
            snapshot: snapshot,
            now: Self.t0,
            catalog: catalog + [nearbyAlighting]
        )
        #expect(detected == nil)
    }

    @Test func isLineServiceViableReturnsFalseForUnfetchedSnapshot() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot()
        #expect(!detector.isLineServiceViable(.purple, snapshot: snapshot, now: Self.t0))
    }

    @Test func isLineServiceViableReturnsFalseWhenLineMissingFromFetchedSnapshot() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot(
            trainArrivals: [arrival(line: .red, station: sourceBoarding, minutesAhead: 5)],
            trainsFetchedAt: Self.t0
        )
        #expect(!detector.isLineServiceViable(.purple, snapshot: snapshot, now: Self.t0))
    }

    @Test func isLineServiceViableReturnsTrueWithFreshArrivals() {
        let detector = TransferDetector()
        let snapshot = TransitSnapshot(
            trainArrivals: [arrival(line: .purple, station: sourceTerminus, minutesAhead: 5)],
            trainsFetchedAt: Self.t0
        )
        #expect(detector.isLineServiceViable(.purple, snapshot: snapshot, now: Self.t0))
    }
}
