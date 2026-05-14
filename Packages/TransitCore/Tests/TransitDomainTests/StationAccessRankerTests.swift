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

    @Test func visibleCandidatesIncludeDirectDistanceTiesBeyondTopThree() {
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

        #expect(visibleIds.contains(7))
        #expect(!visibleIds.contains(8))
    }

    @Test func pinnedStationRemainsVisibleOutsideTieBand() {
        let ranker = StationAccessRanker()
        let ranked = ranker.rank([
            candidate(id: 1, directMeters: 600),
            candidate(id: 2, directMeters: 800),
            candidate(id: 3, directMeters: 900),
            candidate(id: 99, directMeters: 3_000),
        ])

        let visibleIds = ranker.visibleCandidates(
            from: ranked,
            pinnedStationId: 99
        ).map(\.station.id)

        #expect(visibleIds.contains(99))
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
