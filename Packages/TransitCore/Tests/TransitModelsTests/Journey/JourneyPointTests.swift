import Foundation
import Testing
@testable import TransitModels

@Suite("JourneyPoint")
struct JourneyPointTests {
    @Test func anchorTitleAndNilCoordinate() {
        let home: JourneyPoint = .anchor(.home)
        #expect(home.displayTitle == "Home")
        #expect(home.coordinate == nil)
    }

    @Test func coordinatePoint() {
        let p: JourneyPoint = .coordinate(latitude: 41.9, longitude: -87.65)
        #expect(p.coordinate?.latitude == 41.9)
        #expect(p.coordinate?.longitude == -87.65)
    }

    @Test func stopHasName() {
        let p: JourneyPoint = .stop(systemRef: "1234", name: "Belmont", latitude: 41.9, longitude: -87.65)
        #expect(p.displayTitle == "Belmont")
        #expect(p.coordinate?.latitude == 41.9)
    }

    @Test func stationHasNoCoordinate() {
        let p: JourneyPoint = .station(systemRef: "40360", name: "Belmont", lineHint: "Red")
        #expect(p.displayTitle == "Belmont")
        #expect(p.coordinate == nil)
    }

    @Test func divvyStationCarriesLatLon() {
        let p: JourneyPoint = .divvyStation(stationId: "TA1305000040", name: "Sheridan & Noyes", latitude: 42.06, longitude: -87.68)
        #expect(p.coordinate?.latitude == 42.06)
    }

    @Test func namedPlaceWithoutLatLonHasNilCoordinate() {
        let p: JourneyPoint = .namedPlace(title: "Streeterville", subtitle: nil, latitude: nil, longitude: nil)
        #expect(p.displayTitle == "Streeterville")
        #expect(p.coordinate == nil)
    }

    @Test func codableRoundTripCoversAllCases() throws {
        let points: [JourneyPoint] = [
            .anchor(.work),
            .coordinate(latitude: 41.9, longitude: -87.65),
            .stop(systemRef: "1", name: "Stop", latitude: 41, longitude: -87),
            .station(systemRef: "2", name: "Station", lineHint: nil),
            .divvyStation(stationId: "TA1", name: "Dock", latitude: 41, longitude: -87),
            .namedPlace(title: "T", subtitle: "Sub", latitude: 1, longitude: 2)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in points {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(JourneyPoint.self, from: data)
            #expect(decoded == original)
        }
    }
}
