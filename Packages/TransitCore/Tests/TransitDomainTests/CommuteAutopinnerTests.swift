import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("CommuteAutopinner")
struct CommuteAutopinnerTests {
    @Test func atWorkPinsTowardHomeFromSavedPreferences() {
        let now = date(year: 2026, month: 5, day: 13, hour: 17)
        let autopinner = CommuteAutopinner(clock: FakeClock(now))
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 1,
                    stopId: nil,
                    stationName: "Work Station",
                    line: .blue,
                    directionLabel: "Home",
                    direction: .toHome
                )
            ],
            buses: [
                BusPreference(
                    route: "22",
                    stopId: 100,
                    stopName: "Work Stop",
                    directionLabel: "Southbound",
                    direction: .toHome
                )
            ]
        )

        let result = autopinner.apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: workLocation,
            context: .atWork
        )

        #expect(result.changed)
        #expect(result.direction == .toHome)
        #expect(result.preferences.pinSource == .automatic)
        #expect(result.preferences.pinnedLine == .blue)
        #expect(result.preferences.pinnedStationId == 1)
        #expect(result.preferences.pinnedBusRoute == "22")
        #expect(result.preferences.pinnedBusDirection == "Southbound")
    }

    @Test func recentManualPinSuppressesAutopin() {
        let now = date(year: 2026, month: 5, day: 13, hour: 17)
        var prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 1,
                    stopId: nil,
                    stationName: "Work Station",
                    line: .blue,
                    directionLabel: "Home",
                    direction: .toHome
                )
            ],
            pinnedLine: .red,
            lastManualPinAt: now.addingTimeInterval(-10 * 60)
        )
        prefs.markManualPin(at: now.addingTimeInterval(-10 * 60))

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: workLocation,
            context: .atWork
        )

        #expect(!result.changed)
        #expect(result.reason == .manualOverride)
        #expect(result.preferences.pinnedLine == .red)
    }

    @Test func homeWeekdayMorningUsesToWorkFallbackUntilEnoughHistory() {
        let now = date(year: 2026, month: 5, day: 13, hour: 8)
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 2,
                    stopId: nil,
                    stationName: "Home Station",
                    line: .brown,
                    directionLabel: "Loop",
                    direction: .toWork
                )
            ]
        )

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome
        )

        #expect(result.changed)
        #expect(result.direction == .toWork)
        #expect(result.preferences.pinnedLine == .brown)
    }

    @Test func homeWeekdayOutsideLearnedWindowDoesNotPinWork() {
        let now = date(year: 2026, month: 5, day: 13, hour: 15)
        var profile = MobilityProfile.empty
        let calendar = FakeClock(now).calendar
        for day in [6, 7, 8] {
            profile.recordObservation(
                context: .elsewhere,
                source: .exitedHome,
                direction: .toWork,
                at: date(year: 2026, month: 5, day: day, hour: 8),
                calendar: calendar
            )
        }
        var prefs = UserRoutePreferences(pinnedLine: .brown, pinSource: .automatic)
        prefs.markAutomaticPin(direction: .toWork, at: now.addingTimeInterval(-3600))

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: homeLocation,
            context: .atHome
        )

        #expect(result.changed)
        #expect(result.reason == .cleared)
        #expect(result.preferences.pinnedLine == nil)
    }

    @Test func elsewherePinsTowardHome() {
        let now = date(year: 2026, month: 5, day: 13, hour: 9)
        let prefs = UserRoutePreferences(
            buses: [
                BusPreference(
                    route: "66",
                    stopId: 200,
                    stopName: "Nearby Stop",
                    directionLabel: "Westbound",
                    direction: .toHome
                )
            ]
        )

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: workLocation,
            context: .elsewhere
        )

        #expect(result.changed)
        #expect(result.direction == .toHome)
        #expect(result.preferences.pinnedBusRoute == "66")
    }

    @Test func stationaryAtHomeInMorningSuppressesWorkPin() {
        let now = date(year: 2026, month: 5, day: 13, hour: 8)
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 2,
                    stopId: nil,
                    stationName: "Home Station",
                    line: .brown,
                    directionLabel: "Loop",
                    direction: .toWork
                )
            ]
        )

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .stationary
        )

        #expect(!result.changed)
        #expect(result.reason == .suppressedByMotion)
        #expect(result.preferences.pinnedLine == nil)
    }

    @Test func walkingAtHomeWithoutHistorySurfacesWorkPin() {
        // 10pm on a weekday — far outside the 5–11 AM heuristic window. Without
        // motion, the autopinner would refuse to surface .toWork; with motion
        // == .walking, walking is treated as positive intent and overrides
        // the hour-bucket fallback.
        let now = date(year: 2026, month: 5, day: 13, hour: 22)
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 2,
                    stopId: nil,
                    stationName: "Home Station",
                    line: .brown,
                    directionLabel: "Loop",
                    direction: .toWork
                )
            ]
        )

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .walking
        )

        #expect(result.changed)
        #expect(result.direction == .toWork)
        #expect(result.preferences.pinnedLine == .brown)
    }

    @Test func automotiveMidCommuteHoldsExistingAutopin() {
        // The user is on a bus driving past the home region after exiting.
        // Region-edge events shouldn't be allowed to churn the pin while the
        // motion coprocessor reports the user is actively riding.
        let now = date(year: 2026, month: 5, day: 13, hour: 8, minute: 30)
        var prefs = UserRoutePreferences(
            pinnedLine: .brown,
            pinnedStationId: 7,
            pinSource: .automatic
        )
        prefs.markAutomaticPin(direction: .toWork, at: now.addingTimeInterval(-15 * 60))

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .automotive
        )

        #expect(!result.changed)
        #expect(result.reason == .heldDuringTransit)
        #expect(result.preferences.pinnedLine == .brown)
        #expect(result.preferences.pinSource == .automatic)
    }

    // MARK: - nextAnchorHint tiebreaker

    @Test func hintBoostBreaksTieBetweenEquallyScoredObservations() {
        // Two observations recorded at the same instant for two different
        // train lines. Without a hint, both score identically and the
        // dictionary iteration order picks the winner (i.e. nondeterministic
        // in practice; the existing `max(by:)` tie-breaks on insertion order).
        // With a hint that matches one of them, the boost makes that one win
        // every time.
        let now = date(year: 2026, month: 5, day: 13, hour: 17)
        let calendar = FakeClock(now).calendar
        let recorded = now.addingTimeInterval(-30 * 60)
        var profile = MobilityProfile.empty
        // Brown line observation, station 100.
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: .brown,
            stationId: 100,
            busRoute: nil,
            busDirection: nil,
            at: recorded,
            calendar: calendar
        )
        // Blue line observation, station 200.
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: .blue,
            stationId: 200,
            busRoute: nil,
            busDirection: nil,
            at: recorded,
            calendar: calendar
        )
        let prefs = UserRoutePreferences()

        // Without a hint, the result picks one — we accept either.
        let unhinted = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: workLocation,
            context: .atWork
        )
        // Smoke check: pinning did happen.
        #expect(unhinted.changed)
        #expect(unhinted.preferences.pinnedLine == .blue || unhinted.preferences.pinnedLine == .brown)

        // With a hint matching the blue station, blue wins.
        let blueHinted = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: workLocation,
            context: .atWork,
            nextAnchorHint: .lStation(stationId: 200)
        )
        #expect(blueHinted.changed)
        #expect(blueHinted.preferences.pinnedLine == .blue)

        // With a hint matching the brown station, brown wins.
        let brownHinted = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: workLocation,
            context: .atWork,
            nextAnchorHint: .lStation(stationId: 100)
        )
        #expect(brownHinted.changed)
        #expect(brownHinted.preferences.pinnedLine == .brown)
    }

    @Test func hintCannotOverrideClearlyStrongerObservation() {
        // One observation is *much* stronger than the other (recorded today,
        // same hour, same weekday), the other is stale. A 25% hint boost
        // applied to the weaker observation must NOT flip the choice.
        let now = date(year: 2026, month: 5, day: 13, hour: 17)
        let calendar = FakeClock(now).calendar
        var profile = MobilityProfile.empty
        // Strong: today, same hour, same weekday → big recency + weekday + hour boost.
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: .red,
            stationId: 300,
            busRoute: nil,
            busDirection: nil,
            at: now.addingTimeInterval(-15 * 60),
            calendar: calendar
        )
        // Weak: 8 weeks ago, off-hour. recency=0, weekdayBoost=0, hourBoost ~0.
        let stale = now.addingTimeInterval(-56 * 24 * 60 * 60)
        profile.recordRouteObservation(
            direction: .toHome,
            context: .atWork,
            line: .blue,
            stationId: 400,
            busRoute: nil,
            busDirection: nil,
            at: stale,
            calendar: calendar
        )
        let prefs = UserRoutePreferences()

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: workLocation,
            context: .atWork,
            // Hint targets the weak observation — must not win.
            nextAnchorHint: .lStation(stationId: 400)
        )

        #expect(result.changed)
        #expect(result.preferences.pinnedLine == .red)
    }

    @Test func nilHintIsByteIdenticalToNoHint() {
        // Sanity: passing `nil` explicitly must match the result of omitting
        // the parameter entirely.
        let now = date(year: 2026, month: 5, day: 13, hour: 17)
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 1,
                    stopId: nil,
                    stationName: "Work Station",
                    line: .blue,
                    directionLabel: "Home",
                    direction: .toHome
                )
            ]
        )

        let omitted = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: workLocation,
            context: .atWork
        )
        let explicitlyNil = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: workLocation,
            context: .atWork,
            nextAnchorHint: nil
        )
        #expect(omitted == explicitlyNil)
    }

    @Test func unknownMotionFallsBackToExistingHeuristic() {
        // Smoke check: with motion == .unknown (older device or no auth),
        // the autopinner must behave identically to the pre-motion version.
        let now = date(year: 2026, month: 5, day: 13, hour: 8)
        let prefs = UserRoutePreferences(
            trains: [
                TrainPreference(
                    mapId: 2,
                    stopId: nil,
                    stationName: "Home Station",
                    line: .brown,
                    directionLabel: "Loop",
                    direction: .toWork
                )
            ]
        )

        let result = CommuteAutopinner(clock: FakeClock(now)).apply(
            preferences: prefs,
            anchors: anchors,
            profile: .empty,
            location: homeLocation,
            context: .atHome,
            motion: .unknown
        )

        #expect(result.changed)
        #expect(result.direction == .toWork)
        #expect(result.preferences.pinnedLine == .brown)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
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
            recordedAt: date(year: 2026, month: 5, day: 13, hour: 8),
            source: .foreground
        )
    }

    private var workLocation: LastKnownLocation {
        LastKnownLocation(
            latitude: 41.880,
            longitude: -87.630,
            recordedAt: date(year: 2026, month: 5, day: 13, hour: 17),
            source: .foreground
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
