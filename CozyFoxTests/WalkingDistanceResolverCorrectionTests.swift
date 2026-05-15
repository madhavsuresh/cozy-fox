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

    @Test func cyclingModeIsNeverCorrected() async {
        let store = Self.makeStore()
        store.record(
            meters: 800,
            expectedTravelTime: 180,
            origin: origin(),
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: 40380),
            mode: .cycling
        )
        // 10 samples with ratio 1.5 — gate definitely passes.
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
        // Cycling is never corrected — raw 180 stands.
        #expect(distance?.expectedTravelTime == 180)
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
