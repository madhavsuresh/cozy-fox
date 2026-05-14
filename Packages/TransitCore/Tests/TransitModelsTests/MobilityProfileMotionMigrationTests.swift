import Foundation
import Testing
@testable import TransitModels

@Suite("MobilityProfile motion-field migration")
struct MobilityProfileMotionMigrationTests {
    @Test func decodesProfileSavedBeforeMotionFieldWasAdded() throws {
        // Payload shape that pre-motion versions of the app wrote to disk via
        // PreferencesStore (ISO-8601 dates, no `motion` field on either
        // observation type).
        let legacyJSON = """
        {
          "observations": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "recordedAt": "2026-05-13T13:00:00Z",
              "context": "atHome",
              "source": "enteredHome",
              "direction": null,
              "weekday": 4,
              "hour": 8
            }
          ],
          "routeObservations": [
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "recordedAt": "2026-05-13T13:00:00Z",
              "direction": "toWork",
              "context": "atHome",
              "line": "brown",
              "stationId": 7,
              "busRoute": null,
              "busDirection": null,
              "weekday": 4,
              "hour": 8
            }
          ],
          "updatedAt": "2026-05-13T13:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(MobilityProfile.self, from: Data(legacyJSON.utf8))

        #expect(profile.observations.count == 1)
        #expect(profile.observations.first?.motion == nil)
        #expect(profile.routeObservations.count == 1)
        #expect(profile.routeObservations.first?.motion == nil)
        #expect(profile.routeObservations.first?.origin == nil)
        #expect(profile.routeObservations.first?.destination == nil)
    }

    @Test func encodesAndDecodesNewMotionField() throws {
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        let when = Date(timeIntervalSinceReferenceDate: 770_000_000)
        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            motion: .walking,
            at: when,
            calendar: calendar
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        let roundTrip = try decoder.decode(MobilityProfile.self, from: data)

        #expect(roundTrip.observations.last?.motion == .walking)
    }

    @Test func encodesAndDecodesRoutePinLocations() throws {
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        let when = Date(timeIntervalSinceReferenceDate: 770_000_000)
        profile.recordRouteObservation(
            direction: .toHome,
            context: .elsewhere,
            line: nil,
            stationId: nil,
            busRoute: "66",
            busDirection: "Eastbound",
            origin: .bucketed(latitude: 41.8801, longitude: -87.7001, label: "elsewhere"),
            destination: .bucketed(latitude: 41.8811, longitude: -87.6401, label: "Logan Square"),
            at: when,
            calendar: calendar
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        let roundTrip = try decoder.decode(MobilityProfile.self, from: data)

        #expect(roundTrip.routeObservations.last?.origin?.label == "elsewhere")
        #expect(roundTrip.routeObservations.last?.destination?.label == "Logan Square")
    }
}
