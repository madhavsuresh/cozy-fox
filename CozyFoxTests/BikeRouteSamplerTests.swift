import Foundation
import Testing
@testable import CozyFox

@MainActor
@Suite("BikeRouteSampler")
struct BikeRouteSamplerTests {
    private static func makeStore() -> BikeRouteStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeRouteSampler-\(UUID().uuidString).json")
        return BikeRouteStore(fileURL: url)
    }

    @Test func startsWithNoActiveRide() {
        let sampler = BikeRouteSampler(routeStore: Self.makeStore())
        #expect(!sampler.hasActiveRideForTests)
    }

    @Test func startRideBeginsAccumulation() {
        let sampler = BikeRouteSampler(routeStore: Self.makeStore())
        sampler.startRide(at: Date())
        #expect(sampler.hasActiveRideForTests)
        #expect(sampler.bufferedSampleCountForTests == 0)
    }

    @Test func startRideIsIdempotent() {
        let sampler = BikeRouteSampler(routeStore: Self.makeStore())
        let first = Date(timeIntervalSinceReferenceDate: 800_000_000)
        sampler.startRide(at: first)
        sampler.appendSampleForTests(latitude: 41.9, longitude: -87.65, at: first)
        // Second startRide while ride active is a no-op — keeps the
        // buffered sample.
        sampler.startRide(at: first.addingTimeInterval(60))
        #expect(sampler.bufferedSampleCountForTests == 1)
    }

    @Test func stopRideWithoutStartReturnsNil() {
        let sampler = BikeRouteSampler(routeStore: Self.makeStore())
        let route = sampler.stopRide(at: Date())
        #expect(route == nil)
    }

    @Test func stopRideWithSamplesPersistsRoute() {
        let store = Self.makeStore()
        let sampler = BikeRouteSampler(routeStore: store)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        sampler.startRide(at: start)
        sampler.appendSampleForTests(latitude: 41.9, longitude: -87.65, at: start.addingTimeInterval(0))
        sampler.appendSampleForTests(latitude: 41.91, longitude: -87.66, at: start.addingTimeInterval(60))
        let route = sampler.stopRide(at: start.addingTimeInterval(600))
        #expect(route != nil)
        #expect(route?.samples.count == 2)
        #expect(store.routes.count == 1)
        #expect(store.routes.first?.samples.count == 2)
    }

    @Test func stopRideWithoutSamplesDiscardsRoute() {
        let store = Self.makeStore()
        let sampler = BikeRouteSampler(routeStore: store)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        sampler.startRide(at: start)
        // No samples appended — the OS never produced a fix.
        let route = sampler.stopRide(at: start.addingTimeInterval(600))
        #expect(route == nil)
        #expect(store.routes.isEmpty)
    }

    @Test func stopRideClearsActiveState() {
        let sampler = BikeRouteSampler(routeStore: Self.makeStore())
        sampler.startRide(at: Date())
        sampler.appendSampleForTests(latitude: 41.9, longitude: -87.65, at: Date())
        _ = sampler.stopRide(at: Date())
        #expect(!sampler.hasActiveRideForTests)
    }
}
