import Foundation
import Testing
import TransitCache
import TransitModels
@testable import TransitDomain

@Suite("PortfolioSnapshot composition")
struct PortfolioSnapshotTests {
    @Test func defaultsInstallEmptyReadersAndNoClosedStations() {
        let snapshot = PortfolioSnapshot(snapshot: .empty)
        #expect(snapshot.userLocation == nil)
        #expect(snapshot.closedStationIDs.isEmpty)
        // Empty readers always answer nil.
        let train = BiasArrivalRef.train(line: .red, stopID: 30074, directionCode: "1")
        #expect(snapshot.biasCorrection.correction(for: train, at: snapshot.now) == nil)
        #expect(
            snapshot.walkingDistance.walkSeconds(
                from: (lat: 41.95, lon: -87.66),
                to: .lStation(40380)
            ) == nil
        )
    }

    @Test func snapshotPassesThroughInjectedReaders() {
        // PortfolioSnapshot is a transparent container — it should not
        // wrap or transform the readers it's handed. A direct call
        // against `snapshot.walkingDistance` must produce exactly what
        // the original reader produces.
        struct ConstantWalker: WalkingDistanceReader {
            let seconds: TimeInterval
            func walkSeconds(
                from origin: (lat: Double, lon: Double),
                to destination: TransitStopRef
            ) -> TimeInterval? { seconds }
        }

        let snapshot = PortfolioSnapshot(
            snapshot: .empty,
            now: Date(timeIntervalSinceReferenceDate: 770_000_000),
            userLocation: PlannerCoordinate(latitude: 41.95, longitude: -87.66),
            walkingDistance: ConstantWalker(seconds: 300),
            biasCorrection: EmptyBiasCorrectionReader(),
            closedStationIDs: [40260]
        )
        #expect(snapshot.closedStationIDs == [40260])
        #expect(snapshot.userLocation?.latitude == 41.95)
        let walk = snapshot.walkingDistance.walkSeconds(
            from: (lat: 41.95, lon: -87.66),
            to: .lStation(40380)
        )
        #expect(walk == 300)
    }

    @Test func snapshotIsSendable() async {
        // Compile-time check: handing the value across an actor boundary
        // must succeed without a warning. The runtime assertion just
        // verifies the field survived.
        let snapshot = PortfolioSnapshot(snapshot: .empty)
        actor Probe {
            func receive(_ s: PortfolioSnapshot) -> Int { s.closedStationIDs.count }
        }
        let count = await Probe().receive(snapshot)
        #expect(count == 0)
    }
}
