import Foundation
import Testing
import TransitDomain
import TransitModels
@testable import CozyFox

@MainActor
@Suite("WalkingDistanceResolver (Phase 5 correction)")
struct WalkingDistanceResolverCorrectionTests {
    private static func makeStore() -> WalkingDistanceStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkResolverTests-\(UUID().uuidString).json")
        return WalkingDistanceStore(fileURL: url)
    }

    private func origin() -> (lat: Double, lon: Double) { (lat: 41.9, lon: -87.65) }

    @Test func cachedReturnsRawWhenEstimateIsBelowGate() async {
        let store = Self.makeStore()
        store.record(
            meters: 400,
            expectedTravelTime: 300,
            origin: origin(),
            stationId: 40380
        )
        // Only 3 samples — gate is 5 by default, so confidentRatio is nil.
        for _ in 0..<3 {
            store.recordWalkSpeedSample(WalkSpeedSample(
                actualSeconds: 360,
                expectedSeconds: 300,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let distance = resolver.cached(origin: origin(), stationId: 40380)
        #expect(distance != nil)
        // Raw MapKit number — no correction applied.
        #expect(distance?.expectedTravelTime == 300)
    }

    @Test func cachedAppliesCorrectionAtGate() async {
        let store = Self.makeStore()
        store.record(
            meters: 400,
            expectedTravelTime: 300,
            origin: origin(),
            stationId: 40380
        )
        // 5 samples each with ratio 1.2 → mean = 1.2, gate passes.
        for _ in 0..<5 {
            store.recordWalkSpeedSample(WalkSpeedSample(
                actualSeconds: 360,
                expectedSeconds: 300,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let distance = resolver.cached(origin: origin(), stationId: 40380)
        #expect(distance != nil)
        // 300 raw * 1.2 corrected = 360.
        #expect(abs((distance?.expectedTravelTime ?? 0) - 360) < 1e-9)
        // Distance (geography) is unchanged.
        #expect(distance?.meters == 400)
    }

    @Test func cyclingModeIsNotAffectedByWalkingEstimate() async {
        // Phase 5b: walking and cycling estimates are independent.
        // Heavily-skewed walking samples must not bleed into cycling
        // results.
        let store = Self.makeStore()
        store.record(
            meters: 800,
            expectedTravelTime: 180,
            origin: origin(),
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: 40380),
            mode: .cycling
        )
        for _ in 0..<10 {
            store.recordWalkSpeedSample(WalkSpeedSample(
                actualSeconds: 450,
                expectedSeconds: 300,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let distance = resolver.cached(
            origin: origin(),
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: 40380),
            mode: .cycling
        )
        // Walking estimate doesn't affect cycling — raw 180 stands.
        #expect(distance?.expectedTravelTime == 180)
    }

    @Test func cyclingAppliesCycleSpeedEstimateAtGate() async {
        let store = Self.makeStore()
        store.record(
            meters: 800,
            expectedTravelTime: 600,
            origin: origin(),
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: 40380),
            mode: .cycling
        )
        // 5 cycle samples at ratio 1.2 → gate clears, mean = 1.2.
        for _ in 0..<5 {
            store.recordCycleSpeedSample(WalkSpeedSample(
                actualSeconds: 720,
                expectedSeconds: 600,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let distance = resolver.cached(
            origin: origin(),
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: 40380),
            mode: .cycling
        )
        #expect(distance != nil)
        // 600 raw * 1.2 corrected = 720.
        #expect(abs((distance?.expectedTravelTime ?? 0) - 720) < 1e-9)
        // Distance (geography) unchanged.
        #expect(distance?.meters == 800)
    }

    @Test func walkingIsNotAffectedByCyclingEstimate() async {
        // Mirror — cycling samples don't leak into walking results.
        let store = Self.makeStore()
        store.record(
            meters: 400,
            expectedTravelTime: 300,
            origin: origin(),
            stationId: 40380
        )
        for _ in 0..<10 {
            store.recordCycleSpeedSample(WalkSpeedSample(
                actualSeconds: 720,
                expectedSeconds: 600,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let distance = resolver.cached(origin: origin(), stationId: 40380)
        #expect(distance?.expectedTravelTime == 300)
    }

    @Test func clearingEstimateImmediatelyRevertsCorrection() async {
        let store = Self.makeStore()
        store.record(
            meters: 400,
            expectedTravelTime: 300,
            origin: origin(),
            stationId: 40380
        )
        for _ in 0..<6 {
            store.recordWalkSpeedSample(WalkSpeedSample(
                actualSeconds: 360,
                expectedSeconds: 300,
                recordedAt: Date()
            ))
        }
        let resolver = WalkingDistanceResolver(store: store)
        let corrected = resolver.cached(origin: origin(), stationId: 40380)
        #expect(abs((corrected?.expectedTravelTime ?? 0) - 360) < 1e-9)

        store.clearWalkSpeedEstimate()
        let raw = resolver.cached(origin: origin(), stationId: 40380)
        #expect(raw?.expectedTravelTime == 300)
    }
}
