import Foundation
import Testing
@testable import TransitModels

@Suite("UserRoutePreferences.portfolios back-compat + round-trip")
struct UserRoutePreferencesPortfoliosTests {
    @Test func legacyPreferencesDecodeToEmptyPortfolios() throws {
        // A preferences blob from before portfolios existed.
        let json = #"{"trains":[],"buses":[],"metra":[]}"#
        let data = Data(json.utf8)
        let prefs = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(prefs.portfolios.isEmpty)
    }

    @Test func portfoliosSurviveCodableRoundTrip() throws {
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [
            RoutePortfolio(
                title: "Home from work",
                direction: .toHome,
                origin: .work,
                destination: .home,
                options: []
            )
        ]
        let data = try JSONEncoder().encode(prefs)
        let round = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(round.portfolios.count == 1)
        #expect(round.portfolios[0].title == "Home from work")
        #expect(round.portfolios[0].direction == .toHome)
    }

    @Test func addingPortfoliosDoesNotDisturbSinglePinFields() throws {
        // Single-pin state stays exactly as set; portfolios are additive.
        var prefs = UserRoutePreferences.empty
        prefs.pinnedLine = .brown
        prefs.pinnedStationId = 40380
        prefs.portfolios = [
            RoutePortfolio(
                title: "Home from work",
                direction: .toHome,
                origin: .work,
                destination: .home
            )
        ]
        let data = try JSONEncoder().encode(prefs)
        let round = try JSONDecoder().decode(UserRoutePreferences.self, from: data)
        #expect(round.pinnedLine == .brown)
        #expect(round.pinnedStationId == 40380)
        #expect(round.portfolios.count == 1)
    }
}
