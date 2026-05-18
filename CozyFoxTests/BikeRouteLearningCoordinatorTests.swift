import Foundation
import SwiftData
import Testing
import TransitCache
import TransitLocation
import TransitModels
@testable import CozyFox

@MainActor
@Suite("Bike route learning coordinator")
struct BikeRouteLearningCoordinatorTests {
    @Test func plannedTripPinDoesNotBlockBikeRouteSampling() async {
        let harness = Self.makeHarness(motions: [.cycling, .walking])
        var prefs = UserRoutePreferences.empty
        prefs.bikeRouteLearningEnabled = true
        prefs.plannedTripPin = Self.plannedTripPin()
        harness.preferences.saveRoutePreferences(prefs)

        let startChangedPins = await harness.coordinator.applyAutopinIfNeeded()
        #expect(!startChangedPins)
        #expect(harness.coordinator.bikeRouteSampler.hasActiveRideForTests)

        harness.coordinator.bikeRouteSampler.appendSampleForTests(
            latitude: 41.9,
            longitude: -87.65,
            at: Date(timeIntervalSinceReferenceDate: 800_000_060)
        )

        let stopChangedPins = await harness.coordinator.applyAutopinIfNeeded()
        #expect(!stopChangedPins)
        #expect(!harness.coordinator.bikeRouteSampler.hasActiveRideForTests)
        #expect(harness.bikeRouteStore.routes.count == 1)
    }

    @Test func disablingBikeRouteLearningStopsAnActiveRide() async {
        let harness = Self.makeHarness(motions: [.cycling, .cycling])
        var prefs = UserRoutePreferences.empty
        prefs.bikeRouteLearningEnabled = true
        harness.preferences.saveRoutePreferences(prefs)

        _ = await harness.coordinator.applyAutopinIfNeeded()
        #expect(harness.coordinator.bikeRouteSampler.hasActiveRideForTests)
        harness.coordinator.bikeRouteSampler.appendSampleForTests(
            latitude: 41.9,
            longitude: -87.65,
            at: Date(timeIntervalSinceReferenceDate: 800_000_060)
        )

        prefs.bikeRouteLearningEnabled = false
        harness.preferences.saveRoutePreferences(prefs)

        _ = await harness.coordinator.applyAutopinIfNeeded()
        #expect(!harness.coordinator.bikeRouteSampler.hasActiveRideForTests)
        #expect(harness.bikeRouteStore.routes.count == 1)
    }

    private struct Harness {
        let coordinator: RefreshCoordinator
        let preferences: PreferencesStore
        let bikeRouteStore: BikeRouteStore
    }

    private static func makeHarness(motions: [MotionContext]) -> Harness {
        let suite = "BikeRouteLearningCoordinator-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let preferences = PreferencesStore(defaults: defaults)
        preferences.saveLastKnownLocation(LastKnownLocation(
            latitude: 41.9,
            longitude: -87.65,
            recordedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            source: .foreground
        ))

        let provider = MotionSequenceLocationProvider(motions: motions)
        let location = LocationCoordinator(provider: provider, preferences: preferences)
        let container = try! ModelContainer.ephemeral()
        let store = TransitStore(container: container, preferences: preferences)
        let walkingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeRouteLearning-Walking-\(UUID().uuidString).json")
        let bikeRouteFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BikeRouteLearning-Routes-\(UUID().uuidString).json")
        let bikeRouteStore = BikeRouteStore(fileURL: bikeRouteFile)
        let coordinator = RefreshCoordinator(
            store: store,
            preferences: preferences,
            location: location,
            walkingStore: WalkingDistanceStore(fileURL: walkingFile),
            bikeRouteStore: bikeRouteStore
        )
        return Harness(
            coordinator: coordinator,
            preferences: preferences,
            bikeRouteStore: bikeRouteStore
        )
    }

    private static func plannedTripPin() -> PlannedTripPin {
        PlannedTripPin(
            destination: PlannedTripPin.Destination(
                kind: .custom,
                title: "Library",
                latitude: 41.884,
                longitude: -87.632
            ),
            title: "Trip to Library",
            summary: "Bike + train",
            expectedArrivalAt: Date(timeIntervalSinceReferenceDate: 800_001_000),
            expectedTravelTime: 900,
            allowMultimodal: true,
            train: nil,
            bus: nil
        )
    }
}

private final class MotionSequenceLocationProvider: LocationProvider, @unchecked Sendable {
    let events = AsyncStream<RegionEvent> { _ in }
    private var motions: [MotionContext]

    init(motions: [MotionContext]) {
        self.motions = motions
    }

    func currentAuthorization() -> LocationAuthorization {
        .authorizedWhenInUse
    }

    func requestWhenInUseAuthorization() {}

    func requestOneShotLocation() async -> LastKnownLocation? {
        LastKnownLocation(
            latitude: 41.9,
            longitude: -87.65,
            recordedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            source: .foreground
        )
    }

    func startMonitoring(home: CommuteAnchors.Anchor?, work: CommuteAnchors.Anchor?) {}

    func stopMonitoring() {}

    func currentMotion() async -> MotionContext {
        if motions.count > 1 {
            return motions.removeFirst()
        }
        return motions.first ?? .unknown
    }
}
