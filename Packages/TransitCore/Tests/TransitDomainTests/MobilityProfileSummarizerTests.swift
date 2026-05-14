import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("MobilityProfileSummarizer")
struct MobilityProfileSummarizerTests {
    @Test func foldsRawObservationsIntoSummaryOnFirstRefresh() {
        // Hand-build a profile whose summary is empty (no auto-fold) so the
        // summarizer has to do the migration itself.
        let calendar = Calendar(identifier: .gregorian)
        let baseline = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let observations = (0..<3).map { offset in
            MobilityProfile.Observation(
                recordedAt: baseline.addingTimeInterval(Double(offset) * 86_400),
                context: .atHome,
                source: .exitedHome,
                direction: .toWork,
                weekday: calendar.component(.weekday, from: baseline.addingTimeInterval(Double(offset) * 86_400)),
                hour: 8
            )
        }
        let profile = MobilityProfile(
            observations: observations,
            routeObservations: [],
            updatedAt: baseline,
            summary: .empty
        )

        let refreshed = MobilityProfileSummarizer().refresh(profile, now: baseline)
        let window = refreshed.summary.departureWindow(source: .exitedHome, direction: .toWork)
        #expect(window?.totalCount == 3)
    }

    @Test func refreshIsIdempotentForAlreadyFoldedObservations() {
        // After record* runs, the summary already reflects the observation
        // and the cursor sits at that observation's date. Calling the
        // summarizer again must not increment any counters.
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            at: now,
            calendar: calendar
        )

        let firstRefresh = MobilityProfileSummarizer().refresh(profile, now: now)
        let secondRefresh = MobilityProfileSummarizer().refresh(firstRefresh, now: now)

        let window = secondRefresh.summary.departureWindow(source: .exitedHome, direction: .toWork)
        #expect(window?.totalCount == 1)
    }

    @Test func refreshConsumesObservationsAfterCursor() {
        let calendar = Calendar(identifier: .gregorian)
        let baseline = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let cursor = baseline.addingTimeInterval(-86_400)

        var profile = MobilityProfile.empty
        profile.summary.lastSummarizedAt = cursor

        // Manually append an observation post-cursor without triggering
        // the auto-fold path, so the summarizer is the one that consumes it.
        profile.observations.append(
            MobilityProfile.Observation(
                recordedAt: baseline,
                context: .atHome,
                source: .exitedHome,
                direction: .toWork,
                weekday: calendar.component(.weekday, from: baseline),
                hour: 8
            )
        )

        let refreshed = MobilityProfileSummarizer().refresh(profile, now: baseline)
        let window = refreshed.summary.departureWindow(source: .exitedHome, direction: .toWork)
        #expect(window?.totalCount == 1)
    }

    @Test func foldsRouteObservationsAcrossModes() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let routeObservations: [MobilityProfile.RouteObservation] = [
            MobilityProfile.RouteObservation(
                recordedAt: now,
                direction: .toWork,
                context: .atHome,
                line: .brown,
                stationId: 7,
                busRoute: nil,
                busDirection: nil,
                origin: .bucketed(latitude: 41.9, longitude: -87.7),
                weekday: calendar.component(.weekday, from: now),
                hour: 8
            ),
            MobilityProfile.RouteObservation(
                recordedAt: now.addingTimeInterval(-86_400),
                direction: .toHome,
                context: .elsewhere,
                line: nil,
                stationId: nil,
                busRoute: "22",
                busDirection: "Southbound",
                origin: .bucketed(latitude: 41.88, longitude: -87.63),
                weekday: calendar.component(.weekday, from: now.addingTimeInterval(-86_400)),
                hour: 17
            ),
        ]

        let profile = MobilityProfile(
            observations: [],
            routeObservations: routeObservations,
            updatedAt: now,
            summary: .empty
        )

        let refreshed = MobilityProfileSummarizer().refresh(profile, now: now)
        let trainKey = MobilityProfileSummary.RoutePattern.key(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.brown.rawValue
        )
        let busKey = MobilityProfileSummary.RoutePattern.key(
            direction: .toHome,
            mode: .bus,
            routeId: "22"
        )
        let trainPattern = refreshed.summary.routePatterns[trainKey]
        let busPattern = refreshed.summary.routePatterns[busKey]
        #expect(trainPattern?.totalCount == 1)
        #expect(trainPattern?.stationCounts["7"] == 1)
        #expect(trainPattern?.originBucketCounts.isEmpty == false)
        #expect(busPattern?.totalCount == 1)
        #expect(busPattern?.directionLabelCounts["Southbound"] == 1)
    }
}
