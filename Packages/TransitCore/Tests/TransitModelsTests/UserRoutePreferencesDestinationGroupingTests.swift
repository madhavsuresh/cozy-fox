import Foundation
import Testing
@testable import TransitModels

/// Covers the backward-compat path on `UserRoutePreferences`:
/// payloads written before destination grouping shipped store a
/// single `pinnedTrainDestination: String?`; new writes store a
/// `pinnedTrainDestinations: [String]?`. The custom decoder accepts
/// either shape.
@Suite("UserRoutePreferences destination grouping")
struct UserRoutePreferencesDestinationGroupingTests {

    @Test func emptyPayloadHasNilDestinations() throws {
        let json = "{}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.pinnedTrainDestinations == nil)
    }

    @Test func legacySingleDestinationDecodesAsArray() throws {
        let json = """
        {"pinnedTrainDestination":"Forest Park"}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.pinnedTrainDestinations == ["Forest Park"])
    }

    @Test func newArrayShapeDecodesDirectly() throws {
        let json = """
        {"pinnedTrainDestinations":["Forest Park","UIC-Halsted"]}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.pinnedTrainDestinations == ["Forest Park", "UIC-Halsted"])
    }

    @Test func newKeyTakesPrecedenceOverLegacyKey() throws {
        // Both keys present (hypothetical mixed payload) — new key wins.
        let json = """
        {"pinnedTrainDestination":"Howard",
         "pinnedTrainDestinations":["Forest Park","UIC-Halsted"]}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.pinnedTrainDestinations == ["Forest Park", "UIC-Halsted"])
    }

    @Test func roundTripEncodesAsArray() throws {
        var prefs = UserRoutePreferences()
        prefs.pinnedTrainDestinations = ["Forest Park", "UIC-Halsted"]
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(decoded.pinnedTrainDestinations == ["Forest Park", "UIC-Halsted"])
        // And the encoded payload uses the new key name (sanity check).
        let payloadString = String(data: data, encoding: .utf8) ?? ""
        #expect(payloadString.contains("pinnedTrainDestinations"))
    }

    @Test func nilDestinationsRoundTrip() throws {
        var prefs = UserRoutePreferences()
        prefs.pinnedTrainDestinations = nil
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(decoded.pinnedTrainDestinations == nil)
    }
}
