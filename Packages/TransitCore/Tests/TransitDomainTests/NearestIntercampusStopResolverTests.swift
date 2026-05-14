import Testing
import TransitDomain
import TransitModels

@Suite("NearestIntercampusStopResolver")
struct NearestIntercampusStopResolverTests {
    @Test func returnsNearbyStopsPerDirection() {
        let resolver = NearestIntercampusStopResolver(maxDistanceMeters: 500)
        let entries = resolver.nearestPerDirection(
            to: (41.8965, -87.6197),
            limitPerDirection: 2
        )

        #expect(entries.contains { $0.direction == .northbound && $0.stop.name == "Ward" })
        #expect(entries.contains { $0.direction == .southbound && $0.stop.name == "Ward" })
    }
}
