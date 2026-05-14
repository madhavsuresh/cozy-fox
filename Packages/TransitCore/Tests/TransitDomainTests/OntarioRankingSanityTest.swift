import Foundation
import Testing
@testable import TransitDomain
import TransitModels

/// Sanity-checks the resolver's behavior for the specific case that
/// motivated the river-crossing penalty: a user in Streeterville
/// expecting Chicago/Franklin to surface for the Brown/Purple line, not
/// a Loop stop across the river. Kept as a guard against re-introducing
/// pure-Haversine ranking later.
@Suite("Ontario / river-penalty ranking")
struct OntarioRankingSanityTest {
    private let ontario = (lat: 41.8930, lon: -87.6182)

    @Test func brownLineNearestFromOntarioIsNorthOfRiver() throws {
        let resolver = NearestStationResolver(maxDistanceMeters: 2_000)
        let top = resolver.closestStations(onLine: .brown, to: ontario, limit: 3)
        // The closest Brown stop should not be on the south side of the
        // river main branch: north-of-river options exist within range and
        // shouldn't be jumped over.
        let first = try #require(top.first)
        #expect(!RiverPenalty.crosses(
            from: ontario,
            to: (first.station.latitude, first.station.longitude)
        ))
        // Chicago/Franklin (id 40710) and Merchandise Mart (id 40460) are
        // both within range and on the same side as the user — at least one
        // should make the top 3.
        let ids = Set(top.map { $0.station.id })
        #expect(ids.contains(40710) || ids.contains(40460))
    }

    @Test func purpleLineNearestFromOntarioIsNorthOfRiver() throws {
        let resolver = NearestStationResolver(maxDistanceMeters: 2_000)
        let station = try #require(resolver.nearest(onLine: .purple, to: ontario))
        #expect(!RiverPenalty.crosses(
            from: ontario,
            to: (station.latitude, station.longitude)
        ))
    }

    @Test func disablingPenaltyReturnsToOldRanking() {
        // Without the penalty, the closest Brown stop from Ontario is
        // State/Lake (south of the river). Confirms the penalty is what's
        // doing the work, not a side-effect of another change.
        let resolver = NearestStationResolver(
            maxDistanceMeters: 2_000,
            appliesRiverPenalty: false
        )
        let first = resolver.closestStations(onLine: .brown, to: ontario, limit: 1).first
        #expect(first?.station.id == 40260) // State/Lake
    }
}
