import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("LocalPredictionEngine")
struct LocalPredictionEngineTests {
    @Test func weekdayHomeDeparturePredictsToWork() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 8)
        var profile = MobilityProfile.empty
        let calendar = FakeClock(now).calendar
        // Three weekday home departures around 8 AM build a learned window.
        // Record oldest-first so the in-built 15-min dedupe doesn't drop
        // out-of-order entries.
        for offset in [21, 14, 7] {
            profile.recordObservation(
                context: .atHome,
                source: .exitedHome,
                direction: .toWork,
                at: now.addingTimeInterval(-Double(offset) * 86_400),
                calendar: calendar
            )
        }

        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: .empty,
            anchors: anchors,
            profile: profile,
            location: homeLocation,
            context: .atHome,
            motion: nil
        )

        #expect(prediction.direction == .toWork)
        #expect(prediction.reason == .noRoute || prediction.reason == .predicted)
        #expect(prediction.departureMatch == .insideLearnedWindow)
    }

    @Test func stationaryAtHomeSuppressesCommutePrediction() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 8)
        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: .empty,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .stationary
        )

        #expect(prediction.direction == nil)
        #expect(prediction.reason == .suppressedByMotion)
    }

    @Test func walkingAtHomeOutsideLearnedWindowStillSurfacesToWork() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 22)
        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: .empty,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .walking
        )

        #expect(prediction.direction == .toWork)
    }

    @Test func summaryRouteSurfacesAfterRawObservationsAgeOut() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 8)
        var summary = MobilityProfileSummary.empty
        let pattern = MobilityProfileSummary.RoutePattern(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.brown.rawValue,
            totalCount: 30,
            weekdayCounts: ["3": 30],
            hourCounts: ["8": 30],
            stationCounts: ["7": 30],
            directionLabelCounts: ["Loop": 30],
            originBucketCounts: ["100:200": 30],
            destinationBucketCounts: ["110:210": 30],
            latestSampleAt: now.addingTimeInterval(-15 * 86_400)
        )
        summary.routePatterns[pattern.key] = pattern
        summary.consumedRouteObservationCount = 30
        // Build a learned departure window so the .atHome branch surfaces .toWork.
        summary.departureWindows[
            MobilityProfileSummary.departureKey(source: .exitedHome, direction: .toWork)
        ] = MobilityProfileSummary.DepartureWindow(
            weekdayHourCounts: ["3:8": 6, "3:9": 2],
            totalCount: 8,
            latestSampleAt: now.addingTimeInterval(-15 * 86_400)
        )
        summary.lastSummarizedAt = now.addingTimeInterval(-86_400)

        let profile = MobilityProfile(
            observations: [],
            routeObservations: [],
            updatedAt: now,
            summary: summary
        )

        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: .empty,
            anchors: anchors,
            profile: profile,
            location: homeLocation,
            context: .atHome,
            motion: nil
        )

        #expect(prediction.direction == .toWork)
        let top = prediction.topCandidate
        #expect(top?.mode == .train)
        #expect(top?.routeId == LineColor.brown.rawValue)
        #expect(top?.source == .summary)
    }

    @Test func disabledAutopinSurfacesDisabledReason() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 8)
        var prefs = UserRoutePreferences.empty
        prefs.autopinEnabled = false
        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: nil
        )

        #expect(prediction.reason == .disabled)
    }

    @Test func missingLocationProducesMissingLocationReason() {
        let now = chicago(year: 2026, month: 5, day: 13, hour: 8)
        let engine = LocalPredictionEngine(clock: FakeClock(now))
        let prediction = engine.predict(
            preferences: .empty,
            anchors: anchors,
            profile: .empty,
            location: nil,
            context: .atHome,
            motion: nil
        )

        #expect(prediction.reason == .missingLocation)
    }

    private var anchors: CommuteAnchors {
        CommuteAnchors(
            home: .init(latitude: 41.950, longitude: -87.650, label: "Home"),
            work: .init(latitude: 41.880, longitude: -87.630, label: "Work")
        )
    }

    private var homeLocation: LastKnownLocation {
        LastKnownLocation(
            latitude: 41.950,
            longitude: -87.650,
            recordedAt: chicago(year: 2026, month: 5, day: 13, hour: 8),
            source: .foreground
        )
    }

    private func chicago(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
