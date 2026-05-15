import Foundation
import SwiftData
import Testing
import TransitCache
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("RefreshCoordinator.evaluatePortfolios")
struct RefreshCoordinatorPortfolioTests {
    private static let belmont = (stationID: 41320, stopID: 30255)
    private static let southport = (stationID: 41440, stopID: 30074)

    // MARK: - Construction

    private static func makeCoordinator(
        suite: String = "RefreshCoordinatorPortfolio-\(UUID().uuidString)"
    ) -> (RefreshCoordinator, PreferencesStore) {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: suite))
        let container = try! ModelContainer.ephemeral()
        let store = TransitStore(container: container, preferences: prefs)
        let walkingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkingDistance-\(UUID().uuidString).json")
        let walkingStore = WalkingDistanceStore(fileURL: walkingFile)
        let coordinator = RefreshCoordinator(
            store: store,
            preferences: prefs,
            location: nil,
            walkingStore: walkingStore
        )
        return (coordinator, prefs)
    }

    private static func arrival(
        line: LineColor = .brown,
        stationID: Int = belmont.stationID,
        stopID: Int = belmont.stopID,
        runNumber: String,
        minutesFromNow: Double,
        from referenceNow: Date
    ) -> Arrival {
        let arrivalAt = referenceNow.addingTimeInterval(minutesFromNow * 60)
        return Arrival(
            id: "\(runNumber)-\(stationID)-\(Int(arrivalAt.timeIntervalSinceReferenceDate))",
            line: line,
            runNumber: runNumber,
            destinationName: "Loop",
            stationId: stationID,
            stationName: "Belmont",
            stopId: stopID,
            directionCode: "5",
            predictedAt: referenceNow,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private static func brownLineOption(
        id: UUID = UUID(),
        boardStationID: Int = belmont.stationID,
        alightStationID: Int = southport.stationID
    ) -> RouteOption {
        RouteOption(
            id: id,
            label: "Brown",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(rawName: "Brown", resolution: .line(.brown)),
                    fromStopID: .lStation(boardStationID),
                    toStopID: .lStation(alightStationID),
                    approximateDistanceMeters: 6_400
                )
            ]
        )
    }

    private static func portfolio(
        id: UUID = UUID(),
        options: [RouteOption]
    ) -> RoutePortfolio {
        RoutePortfolio(
            id: id,
            title: "Home",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: options
        )
    }

    // MARK: - Tests

    @Test func no_portfolios_short_circuits_and_leaves_revision_at_zero() {
        let (coord, _) = Self.makeCoordinator()
        coord.evaluatePortfolios(
            prefs: .empty,
            transitSnapshot: .empty,
            closedStations: []
        )
        #expect(coord.latestPortfolioEvaluations.isEmpty)
        #expect(coord.latestPortfolioRecommendations.isEmpty)
        #expect(coord.portfolioRevision == 0)
    }

    @Test func first_evaluation_populates_evaluations_recommendation_and_revision() {
        let (coord, _) = Self.makeCoordinator()
        let option = Self.brownLineOption()
        let p = Self.portfolio(options: [option])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let now = Date()
        let snap = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 6, from: now)]
        )
        coord.evaluatePortfolios(
            prefs: prefs,
            transitSnapshot: snap,
            closedStations: []
        )

        #expect(coord.latestPortfolioEvaluations[p.id] != nil)
        #expect(coord.latestPortfolioEvaluations[p.id]?.recommendedOptionID == option.id)
        #expect(coord.latestPortfolioRecommendations[p.id]?.optionID == option.id)
        #expect(coord.portfolioRevision == 1)
    }

    @Test func unchanged_recommendation_does_not_bump_revision_again() {
        // Tick 1: recommendation is set, revision goes 0 → 1.
        // Tick 2: same recommendation; revision stays at 1.
        let (coord, _) = Self.makeCoordinator()
        let option = Self.brownLineOption()
        let p = Self.portfolio(options: [option])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let snap = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 6, from: Date())]
        )
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap, closedStations: [])
        #expect(coord.portfolioRevision == 1)

        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap, closedStations: [])
        #expect(coord.portfolioRevision == 1)
    }

    @Test func removing_a_portfolio_clears_its_state_and_bumps_revision() {
        let (coord, _) = Self.makeCoordinator()
        let option = Self.brownLineOption()
        let p = Self.portfolio(options: [option])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let snap = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 6, from: Date())]
        )
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap, closedStations: [])
        #expect(coord.latestPortfolioRecommendations[p.id] != nil)
        let revBefore = coord.portfolioRevision

        // Remove the portfolio. Should clear all state and bump revision.
        prefs.portfolios = []
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap, closedStations: [])
        #expect(coord.latestPortfolioEvaluations.isEmpty)
        #expect(coord.latestPortfolioRecommendations.isEmpty)
        #expect(coord.portfolioRevision == revBefore + 1)
    }

    @Test func hysteresis_state_persists_across_evaluatePortfolios_calls() {
        // Two options; second one consistently has a lower-score
        // arrival. Hysteresis defaults: 2-tick persistence requirement.
        // First tick: keep current (the option that was bootstrapped),
        // second tick: switch.
        let (coord, _) = Self.makeCoordinator()
        let optA = Self.brownLineOption(boardStationID: Self.belmont.stationID)
        let optB = Self.brownLineOption(boardStationID: Self.southport.stationID)
        let p = Self.portfolio(options: [optA, optB])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let now = Date()

        // Tick 1: Both options have similar arrivals. Argmax depends
        // on tiny score differences; let the evaluator pick a winner
        // and capture it.
        let snap1 = TransitSnapshot(
            trainArrivals: [
                Self.arrival(stationID: Self.belmont.stationID, runNumber: "401", minutesFromNow: 5, from: now),
                Self.arrival(stationID: Self.southport.stationID, runNumber: "405", minutesFromNow: 5, from: now),
            ]
        )
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap1, closedStations: [])
        let firstRecommendedID = coord.latestPortfolioRecommendations[p.id]?.optionID
        let revAfterFirst = coord.portfolioRevision
        #expect(firstRecommendedID != nil)

        // Tick 2: A wide gap appears favoring the OTHER option. The
        // candidate flips to the alternative, but hysteresis demands
        // 2 consecutive ticks → no switch yet.
        let alternateID: Int = firstRecommendedID == optA.id
            ? Self.southport.stationID
            : Self.belmont.stationID
        let currentID: Int = firstRecommendedID == optA.id
            ? Self.belmont.stationID
            : Self.southport.stationID

        let snap2 = TransitSnapshot(
            trainArrivals: [
                Self.arrival(stationID: currentID, runNumber: "401", minutesFromNow: 30, from: now),
                Self.arrival(stationID: alternateID, runNumber: "405", minutesFromNow: 5, from: now),
            ]
        )
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap2, closedStations: [])
        // Hysteresis: current still surfaced, no revision bump.
        #expect(coord.latestPortfolioRecommendations[p.id]?.optionID == firstRecommendedID)
        #expect(coord.portfolioRevision == revAfterFirst)

        // Tick 3: same wide gap. Second consecutive tick → switch.
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap2, closedStations: [])
        let switchedID = coord.latestPortfolioRecommendations[p.id]?.optionID
        #expect(switchedID != firstRecommendedID)
        #expect(coord.portfolioRevision == revAfterFirst + 1)
    }

    @Test func recommendation_carries_missCost_when_fallback_exists() {
        let (coord, _) = Self.makeCoordinator()
        let option = Self.brownLineOption()
        let p = Self.portfolio(options: [option])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let now = Date()
        // Two arrivals so the same-route fallback exists.
        let snap = TransitSnapshot(
            trainArrivals: [
                Self.arrival(runNumber: "401", minutesFromNow: 6, from: now),
                Self.arrival(runNumber: "402", minutesFromNow: 14, from: now),
            ]
        )
        coord.evaluatePortfolios(prefs: prefs, transitSnapshot: snap, closedStations: [])

        let recommendation = coord.latestPortfolioRecommendations[p.id]
        #expect(recommendation != nil)
        #expect(recommendation?.missCost != nil)
        #expect(recommendation?.missCost?.collapses == false)
    }

    @Test func closed_station_marks_option_unavailable() {
        let (coord, _) = Self.makeCoordinator()
        let option = Self.brownLineOption(alightStationID: Self.southport.stationID)
        let walkingFallback = RouteOption(
            label: "Walk",
            role: .fallback,
            legs: [RouteOptionLeg(mode: .walking, approximateDistanceMeters: 1_200)]
        )
        let p = Self.portfolio(options: [option, walkingFallback])
        var prefs = UserRoutePreferences.empty
        prefs.portfolios = [p]

        let snap = TransitSnapshot(
            trainArrivals: [Self.arrival(runNumber: "401", minutesFromNow: 5, from: Date())]
        )
        coord.evaluatePortfolios(
            prefs: prefs,
            transitSnapshot: snap,
            closedStations: [Self.southport.stationID]
        )

        // The train option should be unavailable; walking should win.
        let recommended = coord.latestPortfolioRecommendations[p.id]?.optionID
        #expect(recommended == walkingFallback.id)
        let evaluation = coord.latestPortfolioEvaluations[p.id]
        let trainEval = evaluation?.evaluation(for: option.id)
        #expect(trainEval?.available == false)
        if case .closedStation(let ids) = trainEval?.unavailableReason {
            #expect(ids.contains(Self.southport.stationID))
        }
    }
}
