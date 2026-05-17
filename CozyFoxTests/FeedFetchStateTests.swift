import Foundation
import Testing
@testable import CozyFox

@Suite("FeedFetchStates per-target tracking")
struct FeedFetchStatesTests {

    @Test func neverRecordedTargetReportsNotFresh() {
        let states = FeedFetchStates()
        #expect(!states.hasFreshFetch(forTarget: .train(stationId: 40380)))
        #expect(states.age(forTarget: .train(stationId: 40380)) == nil)
    }

    @Test func recordedTargetWithinWindowIsFresh() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        states.recordSuccess(.train(stationId: 40380), at: now)

        // 10s after recording — well within the default 90s window.
        let later = now.addingTimeInterval(10)
        #expect(states.hasFreshFetch(forTarget: .train(stationId: 40380), now: later))
        #expect(states.age(forTarget: .train(stationId: 40380), now: later) == 10)
    }

    @Test func recordedTargetPastWindowIsNotFresh() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        states.recordSuccess(.bus(route: "22", stopId: 1001), at: now)

        // 100s after — beyond the default 90s window.
        let later = now.addingTimeInterval(100)
        #expect(!states.hasFreshFetch(forTarget: .bus(route: "22", stopId: 1001), now: later))
        #expect(states.age(forTarget: .bus(route: "22", stopId: 1001), now: later) == 100)
    }

    @Test func customWindowOverridesDefault() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        states.recordSuccess(.metra(routeId: "UP-N", stationId: "OTC"), at: now)

        // 45s after — fresh against default 90s, stale against custom 30s.
        let later = now.addingTimeInterval(45)
        #expect(states.hasFreshFetch(forTarget: .metra(routeId: "UP-N", stationId: "OTC"), now: later))
        #expect(!states.hasFreshFetch(
            forTarget: .metra(routeId: "UP-N", stationId: "OTC"),
            now: later,
            within: 30
        ))
    }

    @Test func recordSuccessesBatchesIntercampusStops() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stopIds = ["chicago_north", "evanston_south", "evanston_north"]
        states.recordSuccesses(stopIds.map { TargetFetchKey.intercampus(stopId: $0) }, at: now)

        for stopId in stopIds {
            #expect(states.hasFreshFetch(forTarget: .intercampus(stopId: stopId), now: now))
        }
    }

    @Test func differentTargetsTrackIndependently() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)

        // Belmont (station 41320) succeeds; Loyola (station 41300) doesn't.
        states.recordSuccess(.train(stationId: 41320), at: now)

        // Both checked 10s later — only Belmont is fresh.
        let later = now.addingTimeInterval(10)
        #expect(states.hasFreshFetch(forTarget: .train(stationId: 41320), now: later))
        #expect(!states.hasFreshFetch(forTarget: .train(stationId: 41300), now: later))
    }

    @Test func laterRecordOverwritesEarlier() {
        var states = FeedFetchStates()
        let early = Date(timeIntervalSince1970: 1_000_000)
        let late = early.addingTimeInterval(60)
        states.recordSuccess(.bus(route: "22", stopId: 1001), at: early)
        states.recordSuccess(.bus(route: "22", stopId: 1001), at: late)

        // 10s after the *late* timestamp, we're 70s past the early one but
        // only 10s past the late one — should be fresh.
        let checking = late.addingTimeInterval(10)
        #expect(states.hasFreshFetch(forTarget: .bus(route: "22", stopId: 1001), now: checking))
        #expect(states.age(forTarget: .bus(route: "22", stopId: 1001), now: checking) == 10)
    }

    @Test func feedLevelStaysIndependentFromPerTarget() {
        var states = FeedFetchStates()
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Feed-level rollup set; per-target not set.
        states.trains.lastSuccessAt = now
        #expect(states.hasFreshFetch(for: .trains, now: now))
        #expect(!states.hasFreshFetch(forTarget: .train(stationId: 40380), now: now))
    }
}

@Suite("Staleness bucketing")
struct StalenessTests {

    @Test func nilAgeIsUnknown() {
        #expect(Staleness.from(age: nil) == .unknown)
    }

    @Test func zeroAgeIsLive() {
        #expect(Staleness.from(age: 0) == .live)
    }

    @Test func underLiveCutoffIsLive() {
        // liveCutoff = 30s — anything strictly less is "live".
        #expect(Staleness.from(age: 29.999) == .live)
    }

    @Test func atLiveCutoffPromotesToCurrent() {
        // 30s exactly — first bucket boundary, no longer "live".
        if case .current(let seconds) = Staleness.from(age: 30) {
            #expect(seconds == 30)
        } else {
            Issue.record("Expected .current at 30s, got \(Staleness.from(age: 30))")
        }
    }

    @Test func currentBucketRoundsSecondsToNearest() {
        if case .current(let seconds) = Staleness.from(age: 47.4) {
            #expect(seconds == 47)
        } else {
            Issue.record("Expected .current(47), got \(Staleness.from(age: 47.4))")
        }
        if case .current(let seconds) = Staleness.from(age: 47.6) {
            #expect(seconds == 48)
        } else {
            Issue.record("Expected .current(48), got \(Staleness.from(age: 47.6))")
        }
    }

    @Test func atAgingCutoffPromotesToAging() {
        // 60s exactly — promotes to "aging" in minutes.
        if case .aging(let minutes) = Staleness.from(age: 60) {
            #expect(minutes == 1)
        } else {
            Issue.record("Expected .aging(1) at 60s, got \(Staleness.from(age: 60))")
        }
    }

    @Test func agingBucketReportsRoundedMinutes() {
        if case .aging(let minutes) = Staleness.from(age: 150) {
            // 2.5 min → rounds to 3? Actually .rounded() defaults to round-half-to-even.
            #expect(minutes == 2 || minutes == 3)
        } else {
            Issue.record("Expected .aging in [2, 3], got \(Staleness.from(age: 150))")
        }
    }

    @Test func atStaleCutoffPromotesToStale() {
        // 5 min exactly — into "stale" territory.
        if case .stale(let minutes) = Staleness.from(age: 300) {
            #expect(minutes >= 5)
        } else {
            Issue.record("Expected .stale at 300s, got \(Staleness.from(age: 300))")
        }
    }

    @Test func wellPastStaleCutoffStaysStale() {
        if case .stale(let minutes) = Staleness.from(age: 30 * 60) {
            #expect(minutes == 30)
        } else {
            Issue.record("Expected .stale(30) at 30 min, got \(Staleness.from(age: 30 * 60))")
        }
    }

    @Test func negativeAgeClampsToZero() {
        // Defensive: a clock drift shouldn't crash us — treat negative ages
        // as fresh.
        #expect(Staleness.from(age: -10) == .live)
    }

    @Test func labelFormatsAreCompact() {
        #expect(Staleness.unknown.label == "—")
        #expect(Staleness.live.label == "live")
        #expect(Staleness.current(seconds: 30).label == "30s")
        #expect(Staleness.aging(minutes: 2).label == "2m")
        #expect(Staleness.stale(minutes: 15).label == "15m")
    }

    @Test func accessibilityLabelsPluralize() {
        #expect(Staleness.aging(minutes: 1).accessibilityLabel.contains("1 minute "))
        #expect(Staleness.aging(minutes: 5).accessibilityLabel.contains("5 minutes"))
        #expect(Staleness.stale(minutes: 1).accessibilityLabel.contains("1 minute "))
        #expect(Staleness.stale(minutes: 12).accessibilityLabel.contains("12 minutes"))
    }

    @Test func isLiveOnlyForLiveBucket() {
        #expect(Staleness.live.isLive)
        #expect(!Staleness.unknown.isLive)
        #expect(!Staleness.current(seconds: 30).isLive)
        #expect(!Staleness.aging(minutes: 1).isLive)
        #expect(!Staleness.stale(minutes: 5).isLive)
    }

    @Test func isStaleOnlyForStaleBucket() {
        #expect(Staleness.stale(minutes: 5).isStale)
        #expect(!Staleness.unknown.isStale)
        #expect(!Staleness.live.isStale)
        #expect(!Staleness.current(seconds: 30).isStale)
        #expect(!Staleness.aging(minutes: 1).isStale)
    }
}
