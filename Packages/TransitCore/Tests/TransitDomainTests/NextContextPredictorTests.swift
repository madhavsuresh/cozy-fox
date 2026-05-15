import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("NextContextPredictor")
struct NextContextPredictorTests {
    private static var chicagoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }

    private func observation(
        at date: Date,
        context: CommuteContext,
        source: MobilityProfile.Observation.Source = .foreground,
        calendar: Calendar = chicagoCalendar
    ) -> MobilityProfile.Observation {
        MobilityProfile.Observation(
            recordedAt: date,
            context: context,
            source: source,
            direction: nil,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            motion: nil
        )
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        chicagoCalendar.date(from: DateComponents(
            calendar: chicagoCalendar,
            timeZone: chicagoCalendar.timeZone,
            year: year, month: month, day: day, hour: hour
        ))!
    }

    // MARK: - Training

    @Test func trainOnEmptyHistoryProducesEmptyModel() {
        let model = NextContextPredictor.train(from: [])
        #expect(model.bucketCountForTests == 0)
        #expect(model.trainingSampleCount == 0)
    }

    @Test func singleObservationProducesNoTransition() {
        let only = observation(
            at: Self.date(year: 2026, month: 5, day: 14, hour: 8),
            context: .atHome
        )
        let model = NextContextPredictor.train(from: [only])
        #expect(model.trainingSampleCount == 0)
    }

    @Test func consecutivePairsBecomeTransitions() {
        let obs = [
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 7), context: .atHome),
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 8), context: .elsewhere),
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 9), context: .atWork),
        ]
        let model = NextContextPredictor.train(from: obs)
        // Two transitions: home→elsewhere, elsewhere→work.
        #expect(model.trainingSampleCount == 2)
        #expect(model.bucketCountForTests == 2)
    }

    @Test func unknownContextsAreFilteredOnBothSides() {
        let obs = [
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 7), context: .atHome),
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 8), context: .unknown),
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 9), context: .atWork),
        ]
        let model = NextContextPredictor.train(from: obs)
        // (.atHome → .unknown) and (.unknown → .atWork) are both rejected;
        // no transitions remain.
        #expect(model.trainingSampleCount == 0)
    }

    @Test func observationsAreSortedBeforePairing() {
        // Out-of-order input; model still produces the chronologically
        // correct (home → work) transition.
        let later = observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 9), context: .atWork)
        let earlier = observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 7), context: .atHome)
        let model = NextContextPredictor.train(from: [later, earlier])
        #expect(model.trainingSampleCount == 1)
        let hourOfWeek = HourOfWeek.index(
            weekday: Self.chicagoCalendar.component(.weekday, from: earlier.recordedAt),
            hour: 7
        )
        let key = NextContextPredictor.FeatureKey(currentContext: .atHome, hourOfWeek: hourOfWeek)
        #expect(model.transitions[key]?[.atWork] == 1)
    }

    @Test func persistencePairsAreKept() {
        // home → home at 3am is predictive (you stay home). Don't filter.
        let obs = [
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 3), context: .atHome),
            observation(at: Self.date(year: 2026, month: 5, day: 14, hour: 4), context: .atHome),
        ]
        let model = NextContextPredictor.train(from: obs)
        #expect(model.trainingSampleCount == 1)
        let hourOfWeek = HourOfWeek.index(
            weekday: Self.chicagoCalendar.component(.weekday, from: obs[0].recordedAt),
            hour: 3
        )
        let key = NextContextPredictor.FeatureKey(currentContext: .atHome, hourOfWeek: hourOfWeek)
        #expect(model.transitions[key]?[.atHome] == 1)
    }

    // MARK: - Prediction

    @Test func predictReturnsEmptyOnUnknownBucket() {
        let model = NextContextPredictor.train(from: [])
        let predictions = model.predict(currentContext: .atHome, hourOfWeek: 12)
        #expect(predictions.isEmpty)
    }

    @Test func predictReturnsEmptyBelowMinSamples() {
        // Build a model with exactly 4 home→work transitions at hour 7 Monday.
        // The default minSamples = 5 should fail the gate.
        var obs: [MobilityProfile.Observation] = []
        for offset in 0..<4 {
            let day = 11 + offset // Mon-Thu in May 2026
            obs.append(observation(at: Self.date(year: 2026, month: 5, day: day, hour: 7), context: .atHome))
            obs.append(observation(at: Self.date(year: 2026, month: 5, day: day, hour: 8), context: .atWork))
        }
        let model = NextContextPredictor.train(from: obs)
        let hourOfWeek = HourOfWeek.index(weekday: 2, hour: 7) // Mon 7am
        // home → work at Mon 7am: 1 sample (only Monday 11th).
        let predictions = model.predict(currentContext: .atHome, hourOfWeek: hourOfWeek)
        #expect(predictions.isEmpty)
    }

    @Test func predictReturnsTopKAboveGate() {
        // 5 home→work transitions at the same hour-of-week. Each
        // (home, work) pair sits 5 s apart so the home immediately
        // precedes its work in sort order; 10-min gap between pairs
        // keeps everything inside the same hour bucket on Mon 7am.
        var obs: [MobilityProfile.Observation] = []
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        for i in 0..<5 {
            let home = base.addingTimeInterval(Double(i) * 600)
            let work = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: work, context: .atWork))
        }
        let model = NextContextPredictor.train(from: obs)
        let hourOfWeek = HourOfWeek.index(weekday: 2, hour: 7)
        let predictions = model.predict(currentContext: .atHome, hourOfWeek: hourOfWeek)

        #expect(!predictions.isEmpty)
        #expect(predictions.first?.context == .atWork)
        #expect(predictions.first?.anchor == .work)
        #expect(predictions.first?.probability == 1.0)
    }

    @Test func predictRanksByProbabilityThenSamples() {
        // Mixed bucket at Mon 7am: 3 home→work, 2 home→elsewhere,
        // 1 home→home. Total = 6 ≥ gate. Pair gaps of 5 s keep each
        // home → next transition correct in sort order.
        var obs: [MobilityProfile.Observation] = []
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        var slot = 0.0
        for _ in 0..<3 {
            let home = base.addingTimeInterval(slot)
            let work = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: work, context: .atWork))
            slot += 600
        }
        for _ in 0..<2 {
            let home = base.addingTimeInterval(slot)
            let elsewhere = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: elsewhere, context: .elsewhere))
            slot += 600
        }
        do {
            let home = base.addingTimeInterval(slot)
            let stillHome = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: stillHome, context: .atHome))
        }

        let model = NextContextPredictor.train(from: obs)
        let hourOfWeek = HourOfWeek.index(weekday: 2, hour: 7)
        let predictions = model.predict(
            currentContext: .atHome,
            hourOfWeek: hourOfWeek,
            topK: 3,
            minSamples: 5
        )

        #expect(predictions.count == 3)
        #expect(predictions[0].context == .atWork)
        #expect(predictions[1].context == .elsewhere)
        #expect(predictions[2].context == .atHome)
        // Probabilities are 3/6, 2/6, 1/6.
        #expect(abs(predictions[0].probability - 0.5) < 1e-9)
        #expect(abs(predictions[1].probability - (2.0 / 6.0)) < 1e-9)
        #expect(abs(predictions[2].probability - (1.0 / 6.0)) < 1e-9)
    }

    @Test func anchorMappingForKnownContexts() {
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        var obs: [MobilityProfile.Observation] = []
        for i in 0..<5 {
            let home = base.addingTimeInterval(Double(i) * 600)
            let work = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: work, context: .atWork))
        }
        let model = NextContextPredictor.train(from: obs)
        let hourOfWeek = HourOfWeek.index(weekday: 2, hour: 7)
        let predictions = model.predict(currentContext: .atHome, hourOfWeek: hourOfWeek)
        #expect(predictions.first?.anchor == .work)
    }
}
