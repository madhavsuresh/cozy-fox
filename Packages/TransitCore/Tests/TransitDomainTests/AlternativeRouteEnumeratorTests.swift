import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("AlternativeRouteEnumerator")
struct AlternativeRouteEnumeratorTests {
    private let enumerator = AlternativeRouteEnumerator()

    // Synthetic Chicago-ish layout:
    // - origin near home (Logan Square area), destination near downtown (Loop).
    // - Two L stations on Brown, two on Blue.
    // - Two bus routes (22, 56) with stops near both anchors.

    private let home = (lat: 41.929, lon: -87.708)       // ~Logan Square
    private let work = (lat: 41.882, lon: -87.628)        // ~Loop

    private let brownNearHome = LStation(
        id: 1, name: "Brown @ Home", latitude: 41.930, longitude: -87.706,
        servedLines: [.brown]
    )
    private let brownNearWork = LStation(
        id: 2, name: "Brown @ Loop", latitude: 41.886, longitude: -87.630,
        servedLines: [.brown]
    )
    private let blueNearHome = LStation(
        id: 3, name: "Blue @ Home", latitude: 41.929, longitude: -87.712,
        servedLines: [.blue]
    )
    private let blueNearWork = LStation(
        id: 4, name: "Blue @ Loop", latitude: 41.881, longitude: -87.629,
        servedLines: [.blue]
    )
    private let redFarAway = LStation(
        id: 5, name: "Red @ Howard", latitude: 42.019, longitude: -87.673,
        servedLines: [.red]
    )

    private let bus22Home = BusStop(
        id: 100, route: "22", name: "Clark & Logan",
        latitude: 41.930, longitude: -87.709, directionLabel: "Southbound"
    )
    private let bus22Work = BusStop(
        id: 101, route: "22", name: "Clark & Lake",
        latitude: 41.886, longitude: -87.631, directionLabel: "Southbound"
    )
    private let bus56Home = BusStop(
        id: 200, route: "56", name: "Milwaukee & Logan",
        latitude: 41.928, longitude: -87.710, directionLabel: "Eastbound"
    )
    private let bus56Work = BusStop(
        id: 201, route: "56", name: "Milwaukee & Loop",
        latitude: 41.884, longitude: -87.632, directionLabel: "Eastbound"
    )

    private func brownPattern() -> MobilityProfileSummary.RoutePattern {
        MobilityProfileSummary.RoutePattern(
            direction: .toWork,
            mode: .train,
            routeId: "brown",
            totalCount: 50,
            latestSampleAt: Date()
        )
    }

    // MARK: - Trip-time estimation

    @Test func estimatesTrainTrip() {
        let seconds = enumerator.estimateTripSeconds(
            mode: .train,
            routeId: "brown",
            origin: home,
            destination: work,
            lStationCatalog: [brownNearHome, brownNearWork, redFarAway],
            busStopCatalog: []
        )
        // Walk to+from station + 5-min wait + in-vehicle ≈ several
        // minutes. Sanity check: positive and reasonable.
        #expect(seconds != nil)
        #expect((seconds ?? 0) > 0)
        #expect((seconds ?? 0) < 60 * 60)
    }

    @Test func returnsNilWhenNoStationsNearOrigin() {
        // Catalog only has the Red station way up at Howard.
        let seconds = enumerator.estimateTripSeconds(
            mode: .train,
            routeId: "red",
            origin: home,
            destination: work,
            lStationCatalog: [redFarAway],
            busStopCatalog: []
        )
        #expect(seconds == nil)
    }

    @Test func returnsNilForMetra() {
        let seconds = enumerator.estimateTripSeconds(
            mode: .metra,
            routeId: "UP-N",
            origin: home,
            destination: work,
            lStationCatalog: [],
            busStopCatalog: []
        )
        #expect(seconds == nil)
    }

    @Test func returnsNilWhenSameStop() {
        // Origin and destination on top of the same station.
        let seconds = enumerator.estimateTripSeconds(
            mode: .train,
            routeId: "brown",
            origin: home,
            destination: home,
            lStationCatalog: [brownNearHome],
            busStopCatalog: []
        )
        #expect(seconds == nil)
    }

    // MARK: - Enumerate

    @Test func enumerateProducesAlternatives() {
        let result = enumerator.enumerate(
            origin: home,
            destination: work,
            usualPattern: brownPattern(),
            lStationCatalog: [brownNearHome, brownNearWork, blueNearHome, blueNearWork, redFarAway],
            busStopCatalog: [bus22Home, bus22Work, bus56Home, bus56Work]
        )
        #expect(result != nil)
        #expect(result?.usualTripSeconds ?? 0 > 0)
        // Alternatives should include blue + bus 22 + bus 56 (not brown, not red).
        let routeIds = Set(result?.alternatives.map(\.routeId) ?? [])
        #expect(routeIds.contains("blue"))
        #expect(routeIds.contains("22"))
        #expect(routeIds.contains("56"))
        #expect(!routeIds.contains("brown"))
        #expect(!routeIds.contains("red"))
    }

    @Test func enumerateReturnsNilWhenUsualUnreachable() {
        // Brown is the user's habitual, but the catalog only has Red.
        let result = enumerator.enumerate(
            origin: home,
            destination: work,
            usualPattern: brownPattern(),
            lStationCatalog: [redFarAway],
            busStopCatalog: []
        )
        #expect(result == nil)
    }

    // MARK: - Waypoints

    @Test func waypointsReturnsOriginAndDestinationStops() {
        let points = enumerator.waypoints(
            mode: .train,
            routeId: "brown",
            origin: home,
            destination: work,
            lStationCatalog: [brownNearHome, brownNearWork],
            busStopCatalog: []
        )
        #expect(points.count == 2)
        #expect(points.first?.lat == brownNearHome.latitude)
        #expect(points.last?.lat == brownNearWork.latitude)
    }

    @Test func waypointsEmptyForMetra() {
        let points = enumerator.waypoints(
            mode: .metra,
            routeId: "UP-N",
            origin: home,
            destination: work
        )
        #expect(points.isEmpty)
    }
}
