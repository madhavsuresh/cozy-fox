import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("Quiet relevance layer")
struct QuietRelevanceLayerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func personalAccessEstimatorUsesCommuteLegSamples() throws {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420])

        let estimate = try #require(PersonalAccessEstimator(
            profile: profile,
            now: now,
            calendar: calendar
        ).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))

        #expect(estimate.medianSeconds == 360)
        #expect(estimate.conservativeSeconds > estimate.medianSeconds)
        #expect(estimate.confidence > 0.3)
        let pattern = try #require(
            profile.summary.commuteLegs(
                direction: .toWork,
                mode: .train,
                routeId: LineColor.red.rawValue
            ).first
        )
        #expect(pattern.totalCount == 3)
        #expect(pattern.stopId == "41320")
    }

    @Test func reliableLaterArrivalRanksAboveRiskyNextArrival() throws {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420, 360])
        let access = try #require(PersonalAccessEstimator(
            profile: profile,
            now: now,
            calendar: calendar
        ).estimate(
            direction: .toWork,
            mode: .train,
            routeId: LineColor.red.rawValue,
            stopId: "41320"
        ))
        let scorer = TransitOpportunityScorer()

        let risky = scorer.scoreTrain(
            arrival(id: "risky", arrivalAt: now.addingTimeInterval(330)),
            access: access,
            biasCell: nil,
            ghost: nil,
            alerts: [],
            now: now
        )
        let comfortable = scorer.scoreTrain(
            arrival(id: "comfortable", arrivalAt: now.addingTimeInterval(600)),
            access: access,
            biasCell: nil,
            ghost: nil,
            alerts: [],
            now: now
        )

        #expect(risky.catchability == .tooSoon)
        #expect(comfortable.catchability == .comfortable)
        #expect(comfortable.score > risky.score)
    }

    @Test func catchableWindowSurfacesLearnedTrainWithoutPersistingAPin() throws {
        var profile = MobilityProfile.empty
        recordAccessSamples(in: &profile, seconds: [300, 360, 420, 360])
        let prefs = UserRoutePreferences(
            autoStartLiveActivity: true,
            alwaysShowLiveActivity: false
        )

        let maybeSurfaced = CatchableWindowEvaluator().surfacePreferences(
            preferences: prefs,
            profile: profile,
            context: .atHome,
            trainArrivals: [
                arrival(id: "soon", arrivalAt: now.addingTimeInterval(120)),
                arrival(id: "catchable", arrivalAt: now.addingTimeInterval(600)),
            ],
            busPredictions: [],
            metraPredictions: [],
            vehiclePositions: [],
            activeAlerts: [],
            trainsFetchedAt: now,
            cellLookup: { _ in nil },
            now: now,
            calendar: calendar
        )
        let surfaced = try #require(maybeSurfaced)

        #expect(surfaced.pinnedLine == .red)
        #expect(surfaced.pinnedStationId == 41320)
        #expect(prefs.pinnedLine == nil)
    }

    @Test func catchableWindowDoesNotSurfaceWithOnlyLowData() {
        let prefs = UserRoutePreferences(
            autoStartLiveActivity: true,
            alwaysShowLiveActivity: false
        )
        let surfaced = CatchableWindowEvaluator().surfacePreferences(
            preferences: prefs,
            profile: .empty,
            context: .atHome,
            trainArrivals: [arrival(id: "catchable", arrivalAt: now.addingTimeInterval(600))],
            busPredictions: [],
            metraPredictions: [],
            vehiclePositions: [],
            activeAlerts: [],
            trainsFetchedAt: now,
            cellLookup: { _ in nil },
            now: now,
            calendar: calendar
        )

        #expect(surfaced == nil)
    }

    @Test func transferViabilityPenalizesBrokenFirstLeg() {
        let plan = TripPlan(
            summary: "Red Line to Route 22",
            expectedTravelTime: 1_200,
            totalDistanceMeters: 6_000,
            legs: [
                TripLeg(
                    mode: .transit,
                    distanceMeters: 4_000,
                    instructions: "Red Line",
                    transit: nil
                ),
                TripLeg(
                    mode: .transit,
                    distanceMeters: 2_000,
                    instructions: "Route 22",
                    transit: nil
                ),
            ]
        )
        let viable = TransitOpportunityScore(
            id: "viable",
            mode: .train,
            arrivalAt: now.addingTimeInterval(600),
            adjustedArrivalAt: now.addingTimeInterval(600),
            score: 0.8,
            catchability: .comfortable,
            confidence: 0.8
        )
        let broken = TransitOpportunityScore(
            id: "broken",
            mode: .train,
            arrivalAt: now.addingTimeInterval(60),
            adjustedArrivalAt: now.addingTimeInterval(60),
            score: 0.1,
            catchability: .tooSoon,
            confidence: 0.8
        )

        let scorer = TransferViabilityScorer()
        #expect(
            scorer.score(plan: plan, firstLegOpportunity: viable).score
                > scorer.score(plan: plan, firstLegOpportunity: broken).score
        )
    }

    private func recordAccessSamples(
        in profile: inout MobilityProfile,
        seconds: [TimeInterval]
    ) {
        for (offset, seconds) in seconds.enumerated() {
            profile.recordCommuteLegObservation(
                direction: .toWork,
                mode: .train,
                routeId: LineColor.red.rawValue,
                stopId: "41320",
                stopLabel: "Belmont",
                originAnchor: .home,
                destinationAnchor: .work,
                accessSeconds: seconds,
                sampleQuality: .observedBoarding,
                at: now.addingTimeInterval(Double(offset) * 86_400),
                calendar: calendar
            )
        }
    }

    private func arrival(id: String, arrivalAt: Date) -> Arrival {
        Arrival(
            id: id,
            line: .red,
            runNumber: id,
            destinationName: "Howard",
            stationId: 41320,
            stationName: "Belmont",
            stopId: 30182,
            directionCode: "N",
            predictedAt: now,
            arrivalAt: arrivalAt,
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }
}
