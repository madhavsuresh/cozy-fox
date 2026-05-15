import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("WalkingDistanceReader contract")
struct WalkingDistanceReaderTests {
    @Test func emptyReaderReturnsNilForEveryDestinationKind() {
        let reader = EmptyWalkingDistanceReader()
        let origin = (lat: 41.95, lon: -87.66)
        let destinations: [TransitStopRef] = [
            .lStation(40380),
            .lPlatform(30173),
            .bus(1234),
            .metra("PALATINE"),
            .intercampus("evanston-davis"),
        ]
        for destination in destinations {
            #expect(reader.walkSeconds(from: origin, to: destination) == nil)
        }
    }

    @Test func stubConformanceCanSelectivelyAnswerByStopKind() {
        // A test stub showing the protocol's expected behavior: returns
        // a value for L stations and nil for everything else. This is
        // exactly what the v0 app-side `SnapshotWalkingDistanceReader`
        // does before the refresher is extended to populate other
        // catalogs.
        struct StationOnlyStub: WalkingDistanceReader {
            let seconds: TimeInterval
            func walkSeconds(
                from origin: (lat: Double, lon: Double),
                to destination: TransitStopRef
            ) -> TimeInterval? {
                if case .lStation = destination { return seconds }
                return nil
            }
        }

        let reader = StationOnlyStub(seconds: 420)
        let origin = (lat: 41.95, lon: -87.66)
        #expect(reader.walkSeconds(from: origin, to: .lStation(40380)) == 420)
        #expect(reader.walkSeconds(from: origin, to: .bus(1234)) == nil)
        #expect(reader.walkSeconds(from: origin, to: .metra("PALATINE")) == nil)
    }
}
