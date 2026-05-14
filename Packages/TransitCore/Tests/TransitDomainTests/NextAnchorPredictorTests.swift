import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("NextAnchorPredictor")
struct NextAnchorPredictorTests {
    private let predictor = NextAnchorPredictor()
    // 8 AM on Tuesday = hourOfWeek 32 with Monday-anchored indexing.
    private let tueAt8 = HourOfWeek.index(weekday: 3, hour: 8)

    @Test func emptyProfileReturnsNoHint() {
        let result = predictor.predict(
            profile: .empty,
            currentAnchor: .home,
            hourOfWeek: tueAt8
        )
        #expect(result.isEmpty)
    }

    @Test func stratifiedHourlyCorridorsPicked() {
        // Home → Work shows up four times at this hour, Home → Loop once.
        let homeToWork = CorridorSummary(
            origin: .home,
            destination: .work,
            frequency: 4.0,
            dominantMode: .train
        )
        let homeToLoop = CorridorSummary(
            origin: .home,
            destination: .lStation(stationId: 99),
            frequency: 1.0,
            dominantMode: .train
        )
        let profile = LongTermProfile(
            hourlyTopCorridors: [tueAt8: [homeToWork, homeToLoop]]
        )

        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 3
        )

        #expect(result.first?.anchor == .work)
        #expect(result.count == 2)
        // Highest-frequency candidate dominates the probability mass.
        if let first = result.first {
            #expect(first.probability > 0.7)
        }
    }

    @Test func fallsBackToUnstratifiedCorridorsWhenHourlyEmpty() {
        let homeToWork = CorridorSummary(
            origin: .home,
            destination: .work,
            frequency: 5.0,
            dominantMode: .train
        )
        let profile = LongTermProfile(topCorridors: [homeToWork])

        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 3
        )

        #expect(result.first?.anchor == .work)
    }

    @Test func nilCurrentAnchorUsesFutureMarginalHistogram() {
        // 1-hour lookahead from tueAt8 → tueAt9.
        let futureHour = HourOfWeek.index(weekday: 3, hour: 9)
        let profile = LongTermProfile(
            hourlyAnchorHistogram: [
                futureHour: [.work: 6.0, .lStation(stationId: 1): 1.0]
            ]
        )

        let result = predictor.predict(
            profile: profile,
            currentAnchor: nil,
            hourOfWeek: tueAt8,
            limit: 3
        )

        #expect(result.first?.anchor == .work)
        // Work has 6× the weight, so it should dominate the normalized mass.
        if let first = result.first {
            #expect(first.probability > 0.8)
        }
    }

    @Test func belowConfidenceThresholdReturnsEmpty() {
        // Total weight is 0.5 — under the 1.0 confidence gate.
        let weakCorridor = CorridorSummary(
            origin: .home,
            destination: .work,
            frequency: 0.5,
            dominantMode: .train
        )
        let profile = LongTermProfile(
            hourlyTopCorridors: [tueAt8: [weakCorridor]]
        )

        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8
        )

        #expect(result.isEmpty)
    }

    @Test func boundedTopKShape() {
        // Build five candidates with distinct frequencies; ask for the top 2.
        let candidates: [CorridorSummary] = (1...5).map { i in
            CorridorSummary(
                origin: .home,
                destination: .lStation(stationId: i),
                frequency: Double(i),
                dominantMode: .train
            )
        }
        let profile = LongTermProfile(
            hourlyTopCorridors: [tueAt8: candidates]
        )

        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 2
        )

        #expect(result.count == 2)
        // Sorted descending by probability.
        #expect(result[0].anchor == .lStation(stationId: 5))
        #expect(result[1].anchor == .lStation(stationId: 4))
        #expect(result[0].probability > result[1].probability)
    }

    @Test func filtersOutCurrentAnchorFromMarginalFallback() {
        // Marginal histogram contains the current anchor — predictor should
        // never suggest "stay where you are" when there's no corridor data.
        let futureHour = HourOfWeek.index(weekday: 3, hour: 9)
        let profile = LongTermProfile(
            hourlyAnchorHistogram: [
                futureHour: [.home: 10.0, .work: 5.0]
            ]
        )
        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 3
        )
        // No corridor data → falls back to marginal but excludes .home.
        // With currentAnchor set, corridor pass yields nothing, then marginal
        // path filters .home. Only .work remains.
        if !result.isEmpty {
            #expect(result.allSatisfy { $0.anchor != .home })
        }
    }

    @Test func probabilitiesSumToOne() {
        let a = CorridorSummary(origin: .home, destination: .work, frequency: 3, dominantMode: .train)
        let b = CorridorSummary(origin: .home, destination: .lStation(stationId: 7), frequency: 2, dominantMode: .train)
        let profile = LongTermProfile(hourlyTopCorridors: [tueAt8: [a, b]])

        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 5
        )

        let total = result.reduce(0) { $0 + $1.probability }
        #expect(abs(total - 1.0) < 1e-9)
    }

    @Test func zeroLimitReturnsEmpty() {
        let profile = LongTermProfile(
            hourlyTopCorridors: [tueAt8: [
                CorridorSummary(origin: .home, destination: .work, frequency: 10, dominantMode: .train)
            ]]
        )
        let result = predictor.predict(
            profile: profile,
            currentAnchor: .home,
            hourOfWeek: tueAt8,
            limit: 0
        )
        #expect(result.isEmpty)
    }

    @Test func stationaryMotionHalvesScoresAndCanGateOutWeakSignal() {
        // Marginal histogram alone gives weight 1.5 — passes confidence gate
        // normally. With .stationary motion the predictor multiplies by 0.5
        // (→ 0.75 total) which falls below `minConfidence` and returns [].
        let futureHour = HourOfWeek.index(weekday: 3, hour: 9)
        let profile = LongTermProfile(
            hourlyAnchorHistogram: [futureHour: [.work: 1.5]]
        )
        let active = predictor.predict(
            profile: profile,
            currentAnchor: nil,
            hourOfWeek: tueAt8,
            motion: .walking
        )
        #expect(active.first?.anchor == .work)

        let stationary = predictor.predict(
            profile: profile,
            currentAnchor: nil,
            hourOfWeek: tueAt8,
            motion: .stationary
        )
        #expect(stationary.isEmpty)
    }

    @Test func futureHourWrapsAroundWeek() {
        // Sunday 23:00 → hourOfWeek 167. +1 lookahead should wrap to 0
        // (Monday 00:00). The predictor must pull the marginal from there.
        let sunAt23 = HourOfWeek.index(weekday: 1, hour: 23)
        let monAt0 = HourOfWeek.index(weekday: 2, hour: 0)
        #expect(monAt0 == 0)

        let profile = LongTermProfile(
            hourlyAnchorHistogram: [monAt0: [.home: 5.0]]
        )
        let result = predictor.predict(
            profile: profile,
            currentAnchor: nil,
            hourOfWeek: sunAt23
        )
        #expect(result.first?.anchor == .home)
    }

    @Test func isSendableAndCallableOffMain() async {
        let profile = LongTermProfile(
            hourlyTopCorridors: [tueAt8: [
                CorridorSummary(origin: .home, destination: .work, frequency: 5, dominantMode: .train)
            ]]
        )
        let hour = tueAt8
        // Run on a detached, non-main task to prove Sendable conformance.
        let result = await Task.detached { [profile, hour] in
            NextAnchorPredictor().predict(
                profile: profile,
                currentAnchor: .home,
                hourOfWeek: hour
            )
        }.value
        #expect(result.first?.anchor == .work)
    }
}
