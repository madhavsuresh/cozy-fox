import Foundation
import Testing
@testable import TransitModels

/// Covers the backward-compat path for `nearbyDiscoveryEnabled`:
/// payloads written before nearby-on-demand shipped have no such
/// key and must decode to `false` (the default off state). New
/// writes round-trip the explicit bool.
@Suite("UserRoutePreferences nearby discovery")
struct UserRoutePreferencesNearbyDiscoveryTests {

    @Test func emptyPayloadDefaultsToFalse() throws {
        let json = "{}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.nearbyDiscoveryEnabled == false)
    }

    @Test func legacyPayloadWithoutKeyDefaultsToFalse() throws {
        // A representative legacy payload — has other prefs but no
        // nearbyDiscoveryEnabled key. Existing users on first launch
        // after this release should land in the off state.
        let json = """
        {"alwaysShowLiveActivity":true,
         "autopinEnabled":false}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.nearbyDiscoveryEnabled == false)
    }

    @Test func explicitTrueDecodes() throws {
        let json = """
        {"nearbyDiscoveryEnabled":true}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.nearbyDiscoveryEnabled == true)
    }

    @Test func explicitFalseDecodes() throws {
        let json = """
        {"nearbyDiscoveryEnabled":false}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.nearbyDiscoveryEnabled == false)
    }

    @Test func roundTripTrue() throws {
        var prefs = UserRoutePreferences()
        prefs.nearbyDiscoveryEnabled = true
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(decoded.nearbyDiscoveryEnabled == true)
    }

    @Test func roundTripFalse() throws {
        var prefs = UserRoutePreferences()
        prefs.nearbyDiscoveryEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(decoded.nearbyDiscoveryEnabled == false)
    }

    @Test func defaultInitIsOff() {
        let prefs = UserRoutePreferences()
        #expect(prefs.nearbyDiscoveryEnabled == false)
    }
}
