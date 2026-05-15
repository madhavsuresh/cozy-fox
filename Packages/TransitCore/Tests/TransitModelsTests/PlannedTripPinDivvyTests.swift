import Foundation
import Testing
@testable import TransitModels

@Suite("Planned trip Divvy preference")
struct PlannedTripPinDivvyTests {
    @Test func decodesLegacyPinWithDivvyEnabled() throws {
        let legacyJSON = """
        {
          "destination": {
            "kind": "custom",
            "title": "Library",
            "latitude": 41.884,
            "longitude": -87.632
          },
          "title": "Trip to Library",
          "summary": "Brown Line",
          "expectedTravelTime": 900,
          "allowMultimodal": true,
          "trainLegs": [],
          "busLegs": [],
          "metraLegs": []
        }
        """

        let pin = try JSONDecoder().decode(PlannedTripPin.self, from: Data(legacyJSON.utf8))

        #expect(pin.includeDivvyInfo)
    }

    @Test func encodesAndDecodesDivvyPreference() throws {
        let pin = PlannedTripPin(
            destination: PlannedTripPin.Destination(
                kind: .custom,
                title: "Library",
                latitude: 41.884,
                longitude: -87.632
            ),
            title: "Trip to Library",
            summary: "Brown Line",
            expectedArrivalAt: nil,
            expectedTravelTime: 900,
            allowMultimodal: true,
            includeDivvyInfo: false,
            train: nil,
            bus: nil
        )

        let data = try JSONEncoder().encode(pin)
        let roundTrip = try JSONDecoder().decode(PlannedTripPin.self, from: data)

        #expect(!roundTrip.includeDivvyInfo)
        #expect(roundTrip.withIncludeDivvyInfo(true).includeDivvyInfo)
    }
}
