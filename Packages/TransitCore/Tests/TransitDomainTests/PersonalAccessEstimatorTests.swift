import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("PersonalAccessEstimator")
struct PersonalAccessEstimatorTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - Raw observations

    @Test func threeOrMoreRawSamplesProduceMedianBasedEstimate() throws {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420])

        let estimate = try #require(estimator(profile).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))

        #expect(estimate.medianSeconds == 360)
        #expect(estimate.conservativeSeconds > estimate.medianSeconds)
        #expect(estimate.confidence > 0.3)
        #expect(estimate.sampleCount == 3)
    }

    @Test func twoRawSamplesStillProduceAnEstimateWithLowerConfidence() throws {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 420])

        let estimate = try #require(estimator(profile).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))
        #expect(estimate.sampleCount == 2)
        // 2/8 = 0.25 confidence below the 3-sample threshold of ~0.375.
        #expect(estimate.confidence == 0.25)
    }

    @Test func conservativeSecondsAddsAtLeastA45SecondBuffer() throws {
        var profile = MobilityProfile.empty
        // Identical samples → stddev 0 → conservative = median + 45s floor.
        recordAccessSamples(in: &profile, seconds: [300, 300, 300, 300])
        let estimate = try #require(estimator(profile).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))
        #expect(estimate.conservativeSeconds >= estimate.medianSeconds + 45)
    }

    // MARK: - Summary fallback

    @Test func sparseRawFallsBackToSummaryPattern() throws {
        var profile = MobilityProfile.empty
        // Seed a single raw observation — below the 3-sample threshold.
        recordAccessSamples(in: &profile, seconds: [360])
        // The fold inside `recordCommuteLegObservation` populated the
        // summary's commuteLegPatterns dictionary. The estimator should
        // fall back to it when raw is sparse.
        let pattern = try #require(profile.summary.commuteLegs(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue
        ).first)
        #expect(pattern.totalCount == 1)
        #expect(pattern.stopId == "41320")

        let estimate = try #require(estimator(profile).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))
        #expect(estimate.sampleCount == 1)
    }

    @Test func unrelatedRouteProducesNoEstimate() {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420])
        let unrelated = estimator(profile).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.brown.rawValue,
            stopId: "41320"
        )
        #expect(unrelated == nil)
    }

    @Test func wrongDirectionProducesNoEstimate() {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420])
        let homewardEstimate = estimator(profile).estimate(
            direction: .toHome,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        )
        #expect(homewardEstimate == nil)
    }

    @Test func emptyProfileProducesNoEstimate() {
        let est = estimator(.empty).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        )
        #expect(est == nil)
    }

    // MARK: - Helpers

    private func estimator(_ profile: MobilityProfile) -> PersonalAccessEstimator {
        PersonalAccessEstimator(profile: profile, now: now, calendar: calendar)
    }

    private func recordAccessSamples(
        in profile: inout MobilityProfile,
        seconds: [TimeInterval]
    ) {
        for (offset, sample) in seconds.enumerated() {
            profile.recordCommuteLegObservation(
                direction: .toWork,
                mode: .train,
                routeId: LineColor.red.rawValue,
                stopId: "41320",
                stopLabel: "Belmont",
                originAnchor: .home,
                destinationAnchor: .work,
                accessSeconds: sample,
                sampleQuality: .observedBoarding,
                at: now.addingTimeInterval(Double(offset) * 86_400),
                calendar: calendar
            )
        }
    }
}
