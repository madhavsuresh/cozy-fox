import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("PredictiveStationPrefetcher")
struct PredictiveStationPrefetcherTests {
    private static var chicagoCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        chicagoCalendar.date(from: DateComponents(
            calendar: chicagoCalendar,
            timeZone: chicagoCalendar.timeZone,
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private func observation(
        at date: Date,
        context: CommuteContext,
        calendar: Calendar = chicagoCalendar
    ) -> MobilityProfile.Observation {
        MobilityProfile.Observation(
            recordedAt: date,
            context: context,
            source: .foreground,
            direction: nil,
            weekday: calendar.component(.weekday, from: date),
            hour: calendar.component(.hour, from: date),
            motion: nil
        )
    }

    /// Five home→work transitions at the same Mon 7am hourOfWeek so the
    /// predictor's bucket clears the default `minSamples = 5` gate with
    /// a 100% probability for the home→work transition.
    private func homeWorkConfidentObservations() -> [MobilityProfile.Observation] {
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        var obs: [MobilityProfile.Observation] = []
        for i in 0..<5 {
            let home = base.addingTimeInterval(Double(i) * 600)
            let work = home.addingTimeInterval(5)
            obs.append(observation(at: home, context: .atHome))
            obs.append(observation(at: work, context: .atWork))
        }
        return obs
    }

    private let homeAnchor = CommuteAnchors.Anchor(
        latitude: 41.965, longitude: -87.69, label: "Home"
    )
    private let workAnchor = CommuteAnchors.Anchor(
        latitude: 41.882, longitude: -87.62, label: "Work"
    )

    // A tiny synthetic catalog with one station near each anchor and one
    // far away, so the resolver's radius filter is exercised.
    private let stationNearWork = LStation(
        id: 40100, name: "Near Work", latitude: 41.883, longitude: -87.621,
        servedLines: [.red]
    )
    private let stationFarFromAnchors = LStation(
        id: 40200, name: "Far Away", latitude: 42.06, longitude: -87.69,
        servedLines: [.purple]
    )

    // MARK: - Happy path

    @Test func returnsPlanWhenPredictorConfidentTowardWork() {
        var profile = MobilityProfile.empty
        for obs in homeWorkConfidentObservations() {
            profile.observations.append(obs)
        }
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher(radiusMeters: 800, stationLimit: 5)

        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),  // Mon 7am
            catalog: [stationNearWork, stationFarFromAnchors],
            calendar: Self.chicagoCalendar
        )
        #expect(plan != nil)
        #expect(plan?.origin.latitude == workAnchor.latitude)
        #expect(plan?.origin.longitude == workAnchor.longitude)
        #expect(plan?.stations.count == 1)
        #expect(plan?.stations.first?.id == stationNearWork.id)
    }

    // MARK: - Confidence gate

    @Test func returnsNilBelowProbabilityThreshold() {
        var profile = MobilityProfile.empty
        for obs in homeWorkConfidentObservations() {
            profile.observations.append(obs)
        }
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher()

        // Top probability is 1.0 (5/5); set threshold higher so the gate fails.
        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [stationNearWork],
            calendar: Self.chicagoCalendar,
            probabilityThreshold: 1.1  // unreachable
        )
        #expect(plan == nil)
    }

    @Test func returnsNilBelowSampleGate() {
        // Only 1 transition at this bucket → fails default minSamples = 5.
        var profile = MobilityProfile.empty
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        profile.observations.append(observation(at: base, context: .atHome))
        profile.observations.append(observation(at: base.addingTimeInterval(5), context: .atWork))

        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher()
        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [stationNearWork],
            calendar: Self.chicagoCalendar
        )
        #expect(plan == nil)
    }

    // MARK: - Anchor gates

    @Test func returnsNilWhenTargetAnchorMissing() {
        var profile = MobilityProfile.empty
        for obs in homeWorkConfidentObservations() {
            profile.observations.append(obs)
        }
        // No work anchor set — even with a confident predictor, nothing
        // to warm.
        let anchors = CommuteAnchors(home: homeAnchor, work: nil)
        let prefetcher = PredictiveStationPrefetcher()
        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [stationNearWork],
            calendar: Self.chicagoCalendar
        )
        #expect(plan == nil)
    }

    @Test func returnsNilWhenPredictedContextIsNotAnAnchor() {
        // Build observations where home→elsewhere dominates at 7am.
        var profile = MobilityProfile.empty
        let base = Self.date(year: 2026, month: 5, day: 11, hour: 7)
        for i in 0..<5 {
            let home = base.addingTimeInterval(Double(i) * 600)
            let elsewhere = home.addingTimeInterval(5)
            profile.observations.append(observation(at: home, context: .atHome))
            profile.observations.append(observation(at: elsewhere, context: .elsewhere))
        }
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher()
        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [stationNearWork],
            calendar: Self.chicagoCalendar
        )
        // .elsewhere has no anchor coordinate, so nothing to warm.
        #expect(plan == nil)
    }

    // MARK: - Station catalog gates

    @Test func returnsNilWhenNoStationsWithinRadius() {
        var profile = MobilityProfile.empty
        for obs in homeWorkConfidentObservations() {
            profile.observations.append(obs)
        }
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher(radiusMeters: 100)
        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [stationFarFromAnchors],  // ~20 km north
            calendar: Self.chicagoCalendar
        )
        #expect(plan == nil)
    }

    @Test func stationLimitCapsResult() {
        var profile = MobilityProfile.empty
        for obs in homeWorkConfidentObservations() {
            profile.observations.append(obs)
        }
        let anchors = CommuteAnchors(home: homeAnchor, work: workAnchor)
        let prefetcher = PredictiveStationPrefetcher(radiusMeters: 5_000, stationLimit: 2)

        // Three stations near work — limit should cap at 2.
        let near1 = LStation(id: 1, name: "A", latitude: 41.883, longitude: -87.621, servedLines: [.red])
        let near2 = LStation(id: 2, name: "B", latitude: 41.884, longitude: -87.622, servedLines: [.red])
        let near3 = LStation(id: 3, name: "C", latitude: 41.885, longitude: -87.623, servedLines: [.red])

        let plan = prefetcher.plan(
            profile: profile,
            currentContext: .atHome,
            anchors: anchors,
            now: Self.date(year: 2026, month: 5, day: 18, hour: 7),
            catalog: [near1, near2, near3],
            calendar: Self.chicagoCalendar
        )
        #expect(plan?.stations.count == 2)
    }
}
