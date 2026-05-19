import Foundation
import Testing
@testable import TransitModels

/// Covers `recordPinnedBusRoute` / `recordPinnedAmtrakRoute` (MRU ordering,
/// dedup, cap) and the backward-compat decoder path for the two new arrays.
@Suite("UserRoutePreferences recently-pinned routes")
struct UserRoutePreferencesRecentlyPinnedTests {

    @Test func defaultIsEmpty() {
        let prefs = UserRoutePreferences()
        #expect(prefs.recentlyPinnedBusRoutes == [])
        #expect(prefs.recentlyPinnedAmtrakRoutes == [])
    }

    @Test func legacyPayloadDecodesToEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: json)
        #expect(prefs.recentlyPinnedBusRoutes == [])
        #expect(prefs.recentlyPinnedAmtrakRoutes == [])
    }

    @Test func busRecordPrependsNewest() {
        var prefs = UserRoutePreferences()
        prefs.recordPinnedBusRoute("22")
        prefs.recordPinnedBusRoute("66")
        prefs.recordPinnedBusRoute("147")
        #expect(prefs.recentlyPinnedBusRoutes == ["147", "66", "22"])
    }

    @Test func busRecordDeduplicatesAndPromotes() {
        var prefs = UserRoutePreferences()
        prefs.recordPinnedBusRoute("22")
        prefs.recordPinnedBusRoute("66")
        prefs.recordPinnedBusRoute("22")
        #expect(prefs.recentlyPinnedBusRoutes == ["22", "66"])
    }

    @Test func busRecordCapsAtLimit() {
        var prefs = UserRoutePreferences()
        let routes = (0..<(UserRoutePreferences.recentlyPinnedLimit + 4))
            .map { "R\($0)" }
        for route in routes {
            prefs.recordPinnedBusRoute(route)
        }
        #expect(prefs.recentlyPinnedBusRoutes.count == UserRoutePreferences.recentlyPinnedLimit)
        // Newest insertion sits at the front.
        #expect(prefs.recentlyPinnedBusRoutes.first == routes.last)
        // Oldest insertions fell off the end.
        #expect(!prefs.recentlyPinnedBusRoutes.contains("R0"))
    }

    @Test func amtrakRecordBehavesTheSame() {
        var prefs = UserRoutePreferences()
        prefs.recordPinnedAmtrakRoute("54")  // Hiawatha
        prefs.recordPinnedAmtrakRoute("75")  // Empire Builder
        prefs.recordPinnedAmtrakRoute("54")  // Hiawatha again
        #expect(prefs.recentlyPinnedAmtrakRoutes == ["54", "75"])
    }

    @Test func roundTripPersistsArrays() throws {
        var prefs = UserRoutePreferences()
        prefs.recordPinnedBusRoute("22")
        prefs.recordPinnedBusRoute("66")
        prefs.recordPinnedAmtrakRoute("54")

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserRoutePreferences.self, from: data)

        #expect(decoded.recentlyPinnedBusRoutes == ["66", "22"])
        #expect(decoded.recentlyPinnedAmtrakRoutes == ["54"])
    }
}
