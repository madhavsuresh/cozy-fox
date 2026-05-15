import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("MobilityPatternShiftDetector")
struct MobilityPatternShiftDetectorTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let detector = MobilityPatternShiftDetector()

    private func routeObservation(
        recordedAt: Date,
        line: LineColor? = nil,
        busRoute: String? = nil,
        metraRoute: String? = nil
    ) -> MobilityProfile.RouteObservation {
        MobilityProfile.RouteObservation(
            recordedAt: recordedAt,
            direction: .toWork,
            context: .atHome,
            line: line,
            stationId: nil,
            busRoute: busRoute,
            busDirection: nil,
            metraRoute: metraRoute,
            weekday: 2,
            hour: 8
        )
    }

    /// Build a summary whose `routePatterns` declare the supplied list
    /// as the user's top patterns by total count.
    private func summary(
        topPatterns: [(mode: MobilityProfileSummary.RoutePattern.Mode, routeId: String, count: Int)]
    ) -> MobilityProfileSummary {
        var patterns: [String: MobilityProfileSummary.RoutePattern] = [:]
        for entry in topPatterns {
            let pattern = MobilityProfileSummary.RoutePattern(
                direction: .toWork,
                mode: entry.mode,
                routeId: entry.routeId,
                totalCount: entry.count,
                latestSampleAt: Self.now
            )
            patterns[pattern.key] = pattern
        }
        return MobilityProfileSummary(
            departureWindows: [:],
            routePatterns: patterns,
            lastSummarizedAt: Self.now,
            consumedObservationCount: 0,
            consumedRouteObservationCount: 0
        )
    }

    // MARK: - Edge cases

    @Test func emptyProfileReturnsZero() {
        let score = detector.shiftScore(profile: .empty, now: Self.now)
        #expect(score == 0.0)
    }

    @Test func noRecentObservationsReturnsZero() {
        // A profile with summary but no recent route observations.
        var profile = MobilityProfile.empty
        let oldDate = Self.now.addingTimeInterval(-30 * 86_400)
        profile.routeObservations.append(routeObservation(
            recordedAt: oldDate, line: .brown
        ))
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100)])
        )
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(score == 0.0)
    }

    @Test func noLongTermPatternsReturnsZero() {
        // Recent observations but no summary patterns — new user, no
        // baseline to compare against.
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        profile.routeObservations.append(routeObservation(recordedAt: recent, line: .brown))
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(score == 0.0)
    }

    @Test func observationsWithNoRouteFieldsAreIgnored() {
        // Recent observation has neither line/bus/metra — can't classify.
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        profile.routeObservations.append(routeObservation(recordedAt: recent))
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100)])
        )
        let score = detector.shiftScore(profile: profile, now: Self.now)
        // Zero classifiable observations → score is 0 (defensive default).
        #expect(score == 0.0)
    }

    // MARK: - Stable patterns

    @Test func allRecentMatchTopPatternsReturnsZero() {
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        for _ in 0..<5 {
            profile.routeObservations.append(routeObservation(recordedAt: recent, line: .brown))
        }
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100), (.train, "red", 20)])
        )
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(score == 0.0)
    }

    @Test func partialMatchReturnsExpectedFraction() {
        // 3 of 5 recent observations match a top pattern → score = 0.4.
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        for _ in 0..<3 {
            profile.routeObservations.append(routeObservation(recordedAt: recent, line: .brown))
        }
        for _ in 0..<2 {
            // Pink isn't in the top patterns.
            profile.routeObservations.append(routeObservation(recordedAt: recent, line: .pink))
        }
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100)])
        )
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(abs(score - 0.4) < 1e-12)
    }

    // MARK: - Total shift

    @Test func zeroMatchesReturnsOne() {
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        // Long-term: Brown. Recent: bus 22 only.
        profile.routeObservations.append(routeObservation(recordedAt: recent, busRoute: "22"))
        profile.routeObservations.append(routeObservation(recordedAt: recent, busRoute: "22"))
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100)])
        )
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(score == 1.0)
    }

    // MARK: - Window boundary

    @Test func observationsOlderThanWindowAreExcluded() {
        var profile = MobilityProfile.empty
        let inWindow = Self.now.addingTimeInterval(-2 * 86_400)
        let outsideWindow = Self.now.addingTimeInterval(-10 * 86_400)
        // Inside window: matches brown.
        profile.routeObservations.append(routeObservation(recordedAt: inWindow, line: .brown))
        // Outside window: doesn't match — should be ignored.
        profile.routeObservations.append(routeObservation(recordedAt: outsideWindow, busRoute: "22"))
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100)])
        )
        // Only the in-window brown observation counts → 1/1 match → score 0.
        let score = detector.shiftScore(profile: profile, now: Self.now)
        #expect(score == 0.0)
    }

    @Test func customTopKChangesMatchSet() {
        // 3 brown + 2 red recent. Top patterns: brown (100), red (10),
        // blue (5). topK=1 includes only brown → 3/5 = 0.4 shift score.
        // topK=2 includes brown + red → 5/5 = 0.0.
        var profile = MobilityProfile.empty
        let recent = Self.now.addingTimeInterval(-2 * 86_400)
        for _ in 0..<3 {
            profile.routeObservations.append(routeObservation(recordedAt: recent, line: .brown))
        }
        for _ in 0..<2 {
            profile.routeObservations.append(routeObservation(recordedAt: recent, line: .red))
        }
        profile = MobilityProfile(
            observations: profile.observations,
            routeObservations: profile.routeObservations,
            updatedAt: profile.updatedAt,
            summary: summary(topPatterns: [(.train, "brown", 100), (.train, "red", 10), (.train, "blue", 5)])
        )
        #expect(abs(detector.shiftScore(profile: profile, topK: 1, now: Self.now) - 0.4) < 1e-12)
        #expect(detector.shiftScore(profile: profile, topK: 2, now: Self.now) == 0.0)
    }
}
