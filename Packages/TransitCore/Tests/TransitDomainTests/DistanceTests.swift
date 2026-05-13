import Foundation
import Testing
@testable import TransitDomain

@Suite("Haversine distance")
struct DistanceTests {
    @Test func computesRoughlyCorrectDistance() {
        let loop = (lat: 41.8819, lon: -87.6278)
        let wrigley = (lat: 41.9484, lon: -87.6553)
        let meters = Distance.meters(from: loop, to: wrigley)
        // Loop to Wrigley is about 7.5 km.
        #expect(meters > 7_000 && meters < 8_000)
    }

    @Test func zeroForSamePoint() {
        let p = (lat: 41.881, lon: -87.628)
        #expect(Distance.meters(from: p, to: p) < 0.1)
    }
}
