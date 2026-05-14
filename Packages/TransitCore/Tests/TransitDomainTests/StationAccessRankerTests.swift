import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("Station access ranking")
struct StationAccessRankerTests {
    @Test func usesMapKitWalkingRouteWhenPlausible() {
        let ranked = StationAccessRanker().rank([
            candidate(id: 1, directMeters: 1_000, walkingMeters: 1_500, walkingSeconds: 900)
        ])

        #expect(ranked.first?.accessDistanceMeters == 1_500)
        #expect(ranked.first?.displayTravelTime == 900)
        #expect(ranked.first?.isApproximateTravelTime == false)
    }

    @Test func capsInflatedWalkingRouteWithDirectnessProxy() {
        let ranked = StationAccessRanker().rank([
            candidate(id: 1, directMeters: 1_000, walkingMeters: 3_200, walkingSeconds: 2_400)
        ])

        let access = ranked.first?.accessDistanceMeters ?? 0
        #expect(access > 1_640 && access < 1_660)
        #expect(ranked.first?.displayTravelTime ?? 0 < 1_250)
        #expect(ranked.first?.isApproximateTravelTime == true)
    }

    @Test func visibleCandidatesCutAfterClusterBreak() {
        let ranker = StationAccessRanker()
        let ranked = ranker.rank([
            candidate(id: 1, directMeters: 670),
            candidate(id: 2, directMeters: 849),
            candidate(id: 3, directMeters: 853),
            candidate(id: 4, directMeters: 943),
            candidate(id: 5, directMeters: 1_242),
            candidate(id: 6, directMeters: 1_255),
            candidate(id: 7, directMeters: 1_306),
            candidate(id: 8, directMeters: 1_600),
        ])

        let visibleIds = ranker.visibleCandidates(from: ranked).map(\.station.id)

        #expect(visibleIds == [1, 2, 3, 4])
    }

    @Test func visibleCandidatesFollowRollingMeanStdDevCutoff() {
        let ranker = StationAccessRanker(
            routeDirectnessMultiplier: 1.0,
            routeNoiseAllowanceMeters: 0
        )
        let ranked = ranker.rank([
            candidate(id: 1, directMeters: 2_500),
            candidate(id: 2, directMeters: 2_600),
            candidate(id: 3, directMeters: 2_700),
            candidate(id: 4, directMeters: 2_700),
            candidate(id: 5, directMeters: 3_100),
            candidate(id: 6, directMeters: 3_500),
            candidate(id: 7, directMeters: 3_700),
            candidate(id: 8, directMeters: 4_100),
        ])

        let visibleIds = ranker.visibleCandidates(from: ranked).map(\.station.id)

        #expect(visibleIds == [1, 2, 3, 4])
    }

    @Test func visibleCandidatesCutSmoothWalkingSlope() {
        let ranker = StationAccessRanker()
        let ranked = ranker.rank([
            candidate(id: 1, directMeters: 1_600, walkingMeters: 1_800),
            candidate(id: 2, directMeters: 1_700, walkingMeters: 1_950),
            candidate(id: 3, directMeters: 1_760, walkingMeters: 2_100),
            candidate(id: 4, directMeters: 2_000, walkingMeters: 2_250),
            candidate(id: 5, directMeters: 2_180, walkingMeters: 2_400),
            candidate(id: 6, directMeters: 2_330, walkingMeters: 2_550),
            candidate(id: 7, directMeters: 2_510, walkingMeters: 2_700),
        ])

        let visibleIds = ranker.visibleCandidates(from: ranked).map(\.station.id)

        #expect(visibleIds == [1, 2, 3, 4])
    }

    @Test func redLineFromNavyPierCutsBeforeHarrison() {
        let navyPier = (lat: 41.8917, lon: -87.6086)
        let candidates = LStationCatalog.all
            .filter { $0.servedLines.contains(.red) }
            .map { station in
                StationAccessRanker.Candidate(
                    station: station,
                    directDistanceMeters: Distance.meters(
                        from: navyPier,
                        to: (station.latitude, station.longitude)
                    )
                )
            }
        let ranker = StationAccessRanker()
        let visibleNames = ranker
            .visibleCandidates(from: ranker.rank(candidates))
            .map(\.station.name)

        #expect(visibleNames.contains("Grand"))
        #expect(visibleNames.contains("Lake"))
        #expect(visibleNames.count <= 4)
        #expect(!visibleNames.contains("Harrison"))
    }

    @Test func visibleCandidatesDoNotPreserveDistantOutliers() {
        let ranker = StationAccessRanker()
        let ranked = ranker.rank([
            candidate(id: 1, directMeters: 600),
            candidate(id: 2, directMeters: 800),
            candidate(id: 3, directMeters: 900),
            candidate(id: 4, directMeters: 950),
            candidate(id: 99, directMeters: 3_000),
        ])

        let visibleIds = ranker.visibleCandidates(from: ranked).map(\.station.id)

        #expect(visibleIds == [1, 2, 3, 4])
    }

    private func candidate(
        id: Int,
        directMeters: Double,
        walkingMeters: Double? = nil,
        walkingSeconds: TimeInterval? = nil
    ) -> StationAccessRanker.Candidate {
        StationAccessRanker.Candidate(
            station: LStation(
                id: id,
                name: "Station \(id)",
                latitude: 41,
                longitude: -87,
                servedLines: [.purple]
            ),
            directDistanceMeters: directMeters,
            walkingDistanceMeters: walkingMeters,
            walkingTravelTime: walkingSeconds
        )
    }
}
