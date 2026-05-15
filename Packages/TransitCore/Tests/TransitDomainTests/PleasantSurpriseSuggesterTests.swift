import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("PleasantSurpriseSuggester")
struct PleasantSurpriseSuggesterTests {
    private let suggester = PleasantSurpriseSuggester()
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func profile(
        topRoute: (mode: MobilityProfileSummary.RoutePattern.Mode, routeId: String, count: Int)? = nil,
        recentObservations: [(mode: MobilityProfileSummary.RoutePattern.Mode, routeId: String)] = []
    ) -> MobilityProfile {
        var summary = MobilityProfileSummary.empty
        if let topRoute {
            let pattern = MobilityProfileSummary.RoutePattern(
                direction: .toWork,
                mode: topRoute.mode,
                routeId: topRoute.routeId,
                totalCount: topRoute.count,
                latestSampleAt: Self.now
            )
            summary.routePatterns[pattern.key] = pattern
        }
        let routeObs = recentObservations.map { (mode, routeId) in
            MobilityProfile.RouteObservation(
                recordedAt: Self.now.addingTimeInterval(-60),  // recent
                direction: .toWork,
                context: .atHome,
                line: mode == .train ? LineColor(rawValue: routeId) : nil,
                stationId: nil,
                busRoute: mode == .bus ? routeId : nil,
                busDirection: nil,
                metraRoute: mode == .metra ? routeId : nil,
                weekday: 2, hour: 8
            )
        }
        return MobilityProfile(
            observations: [],
            routeObservations: routeObs,
            updatedAt: nil,
            summary: summary
        )
    }

    private func alt(
        mode: MobilityProfileSummary.RoutePattern.Mode,
        routeId: String,
        minutes: Double
    ) -> PleasantSurpriseSuggester.AlternativeRoute {
        PleasantSurpriseSuggester.AlternativeRoute(
            mode: mode,
            routeId: routeId,
            displayName: "\(mode.rawValue) \(routeId)",
            projectedSeconds: minutes * 60
        )
    }

    // MARK: - Direction inference

    @Test func suggestsForAtHomeContext() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 32)],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result != nil)
        #expect(result?.direction == .toWork)
    }

    @Test func returnsNilForElsewhere() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .elsewhere,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 32)],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result == nil)
    }

    // MARK: - Gates

    @Test func returnsNilWithoutTopPattern() {
        let p = profile(topRoute: nil)
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 32)],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result == nil)
    }

    @Test func returnsNilWithoutUsualTripSeconds() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 32)],
            usualTripSeconds: nil,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result == nil)
    }

    @Test func returnsNilWhenSameRouteAsUsual() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .train, routeId: "brown", minutes: 32)],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result == nil)
    }

    @Test func returnsNilWhenPenaltyExceedsBudget() {
        let p = profile(topRoute: (.train, "brown", 50))
        // Usual = 30 min; budget = max(7.5, 5) = 7.5 min.
        // Alt = 40 min → penalty 10 min, over budget.
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 40)],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result == nil)
    }

    @Test func absoluteBudgetCarriesShortTrips() {
        let p = profile(topRoute: (.train, "brown", 50))
        // Usual = 10 min; 25% = 2.5 min — but the 5-min absolute
        // floor takes over. Alt = 14 min → penalty 4 min, within.
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [alt(mode: .bus, routeId: "22", minutes: 14)],
            usualTripSeconds: 10 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result != nil)
        #expect(result?.extraMinutes == 4)
    }

    @Test func excludesRecentlyObservedAlternatives() {
        // User has taken the 22 bus in the last 14 days — suppress that
        // candidate. Fall back to the train alternative.
        let p = profile(
            topRoute: (.train, "brown", 50),
            recentObservations: [(.bus, "22")]
        )
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [
                alt(mode: .bus, routeId: "22", minutes: 32),
                alt(mode: .train, routeId: "red", minutes: 33)
            ],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result?.routeId == "red")
    }

    @Test func excludesSuppressedAlternatives() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [
                alt(mode: .bus, routeId: "22", minutes: 32),
                alt(mode: .train, routeId: "red", minutes: 33)
            ],
            usualTripSeconds: 30 * 60,
            isSuppressed: { key in key == "pleasantSurprise:bus:22" },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result?.routeId == "red")
    }

    // MARK: - Ranking

    @Test func picksLowestTimePenaltyFirst() {
        let p = profile(topRoute: (.train, "brown", 50))
        let result = suggester.suggest(
            currentContext: .atHome,
            profile: p,
            alternatives: [
                alt(mode: .train, routeId: "red", minutes: 34),  // +4 min
                alt(mode: .bus, routeId: "22", minutes: 32)      // +2 min
            ],
            usualTripSeconds: 30 * 60,
            isSuppressed: { _ in false },
            recentObservationCutoff: Self.now.addingTimeInterval(-14 * 86_400)
        )
        #expect(result?.routeId == "22")
        #expect(result?.extraMinutes == 2)
    }

    @Test func proseFormat() {
        let suggestion = PleasantSurpriseSuggester.Suggestion(
            routeKey: "pleasantSurprise:bus:22",
            direction: .toWork,
            mode: .bus,
            routeId: "22",
            displayName: "22 Clark",
            extraMinutes: 3
        )
        #expect(suggestion.prose == "Try 22 Clark today? +3m vs your usual.")
    }
}
