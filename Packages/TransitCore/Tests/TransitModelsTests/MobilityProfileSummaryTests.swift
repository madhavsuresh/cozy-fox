import Foundation
import Testing
@testable import TransitModels

@Suite("MobilityProfile summary decoding & retention")
struct MobilityProfileSummaryTests {
    @Test func decodesProfileSavedBeforeSummaryFieldExisted() throws {
        // A real profile blob from a pre-summary build, missing the `summary`
        // key entirely. The decoder must default to an empty summary AND
        // backfill it from the raw observations so the existing 90-day
        // history isn't lost when the new 14-day pruner runs.
        let legacyJSON = """
        {
          "observations": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "recordedAt": "2026-05-01T13:00:00Z",
              "context": "atHome",
              "source": "exitedHome",
              "direction": "toWork",
              "weekday": 6,
              "hour": 8
            },
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "recordedAt": "2026-05-02T13:00:00Z",
              "context": "atHome",
              "source": "exitedHome",
              "direction": "toWork",
              "weekday": 7,
              "hour": 8
            }
          ],
          "routeObservations": [],
          "updatedAt": "2026-05-02T13:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(MobilityProfile.self, from: Data(legacyJSON.utf8))

        #expect(profile.observations.count == 2)
        // Backfill should have populated the departure window.
        let window = profile.summary.departureWindow(source: .exitedHome, direction: .toWork)
        let unwrapped = try #require(window)
        #expect(unwrapped.totalCount == 2)
        #expect(unwrapped.count(weekday: 6, hour: 8) == 1)
        #expect(unwrapped.count(weekday: 7, hour: 8) == 1)
        #expect(profile.summary.lastSummarizedAt != nil)
    }

    @Test func decodesProfileWithExistingSummaryWithoutRefolding() throws {
        // Round-trip a newly-built profile to make sure the decoder doesn't
        // re-fold observations that have already been counted.
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            at: Date(timeIntervalSinceReferenceDate: 770_000_000),
            calendar: calendar
        )
        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            at: Date(timeIntervalSinceReferenceDate: 770_086_400),
            calendar: calendar
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        let roundTrip = try decoder.decode(MobilityProfile.self, from: data)

        let window = try #require(
            roundTrip.summary.departureWindow(source: .exitedHome, direction: .toWork)
        )
        #expect(window.totalCount == 2)
    }

    @Test func prunesRawObservationsOlderThan14Days() {
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let twentyDaysAgo = now.addingTimeInterval(-20 * 86_400)
        let oneDayAgo = now.addingTimeInterval(-86_400)

        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            at: twentyDaysAgo,
            calendar: calendar
        )
        profile.recordObservation(
            context: .atHome,
            source: .exitedHome,
            direction: .toWork,
            at: oneDayAgo,
            calendar: calendar
        )

        #expect(profile.observations.count == 1)
        #expect(profile.observations.first?.recordedAt == oneDayAgo)
        // But the summary keeps the long-term count.
        let window = profile.summary.departureWindow(source: .exitedHome, direction: .toWork)
        #expect(window?.totalCount == 2)
    }

    @Test func summaryRetainsRoutePatternsAfterPruning() {
        var profile = MobilityProfile.empty
        let calendar = Calendar(identifier: .gregorian)
        let baseline = Date(timeIntervalSinceReferenceDate: 770_000_000)

        for offset in 0..<5 {
            let date = baseline.addingTimeInterval(-Double(20 + offset) * 86_400)
            profile.recordRouteObservation(
                direction: .toWork,
                context: .atHome,
                line: .brown,
                stationId: 7,
                busRoute: nil,
                busDirection: nil,
                origin: .bucketed(latitude: 41.9, longitude: -87.7),
                at: date,
                calendar: calendar
            )
        }
        // Trigger pruning by recording one recent observation.
        profile.recordRouteObservation(
            direction: .toWork,
            context: .atHome,
            line: .brown,
            stationId: 7,
            busRoute: nil,
            busDirection: nil,
            origin: .bucketed(latitude: 41.9, longitude: -87.7),
            at: baseline,
            calendar: calendar
        )

        #expect(profile.routeObservations.count == 1)
        let key = MobilityProfileSummary.RoutePattern.key(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.brown.rawValue
        )
        let pattern = profile.summary.routePatterns[key]
        #expect(pattern?.totalCount == 6)
    }
}
