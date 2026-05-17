import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BusGeometryBlender")
struct BusGeometryBlenderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let pattern = BusPattern(
        id: 4042,
        route: "65",
        directionName: "Westbound",
        lengthFeet: 3200,
        detourId: nil,
        points: [
            BusPatternPoint(sequence: 1, latitude: 41.8919, longitude: -87.6182,
                            patternDistanceFeet: 0, kindRaw: "S",
                            stopId: 456, stopName: "Grand & McClurg"),
            BusPatternPoint(sequence: 2, latitude: 41.8919, longitude: -87.6225,
                            patternDistanceFeet: 1160, kindRaw: "S",
                            stopId: 457, stopName: "Grand & Columbus"),
            BusPatternPoint(sequence: 3, latitude: 41.8919, longitude: -87.6300,
                            patternDistanceFeet: 3200, kindRaw: "S",
                            stopId: 458, stopName: "Grand & Michigan"),
        ]
    )

    private func prediction(
        stopId: Int = 457,
        ctaEtaSeconds: TimeInterval
    ) -> BusPrediction {
        BusPrediction(
            id: "65-\(stopId)-test",
            route: "65",
            routeName: "65 Grand",
            vehicleId: "1234",
            stopId: stopId,
            stopName: "test",
            destinationName: "Grand/Nordica",
            directionName: "Westbound",
            generatedAt: Self.now.addingTimeInterval(-15),
            arrivalAt: Self.now.addingTimeInterval(ctaEtaSeconds),
            isDelayed: false,
            isApproaching: false
        )
    }

    private func vehicle(pdist: Double) -> VehiclePosition {
        VehiclePosition(
            id: "1234", mode: .bus, route: "65",
            latitude: 41.8919, longitude: -87.6225,
            heading: 270, destinationName: "Grand/Nordica",
            nextStopId: nil, patternId: 4042, patternDistanceFeet: pdist,
            observedAt: Self.now.addingTimeInterval(-15)
        )
    }

    /// Build a history that yields a target median speed (ft/s) over 4
    /// samples, 30 s apart. Each step advances pdist by `targetSpeed * 30`.
    private func history(targetSpeed: Double, samples: Int = 4) -> [BusVehicleHistorySample] {
        var samplesArr: [BusVehicleHistorySample] = []
        for i in 0..<samples {
            samplesArr.append(BusVehicleHistorySample(
                vehicleId: "1234",
                observedAt: Self.now.addingTimeInterval(-Double(samples - i) * 30),
                patternId: 4042,
                patternDistanceFeet: Double(i) * targetSpeed * 30
            ))
        }
        return samplesArr
    }

    @Test("Robust median speed drops zero/negative deltas and out-of-bounds")
    func robustMedianHandlesNoise() {
        let h: [BusVehicleHistorySample] = [
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-120),
                  patternId: 4042, patternDistanceFeet: 0),
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-90),
                  patternId: 4042, patternDistanceFeet: 300),    // 10 ft/s
            // Negative delta — vehicle pdist jitter; drop.
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-60),
                  patternId: 4042, patternDistanceFeet: 280),
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-30),
                  patternId: 4042, patternDistanceFeet: 580),    // 10 ft/s
            // Implausibly fast — drop.
            .init(vehicleId: "1234", observedAt: Self.now,
                  patternId: 4042, patternDistanceFeet: 8_000),
        ]
        let speed = BusGeometryBlender.robustMedianSpeedFtPerSecond(h)
        // Only the two 10 ft/s segments survive → median 10.
        #expect(speed == 10)
    }

    @Test("Robust median returns nil when history has no positive deltas")
    func robustMedianReturnsNilWithoutEvidence() {
        let stalled: [BusVehicleHistorySample] = [
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-60),
                  patternId: 4042, patternDistanceFeet: 100),
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-30),
                  patternId: 4042, patternDistanceFeet: 100),
            .init(vehicleId: "1234", observedAt: Self.now,
                  patternId: 4042, patternDistanceFeet: 100),
        ]
        #expect(BusGeometryBlender.robustMedianSpeedFtPerSecond(stalled) == nil)
    }

    @Test("CTA and geometry agree → blend 0.68 CTA + 0.32 geometry")
    func blendAgreeWeighted() {
        // CTA ETA 120 s. Vehicle at pdist 700 of stop 457 (pdist 1160) →
        // remaining 460 ft. Speed 5 ft/s → geometry ETA 92 s. |Δ| = 28 s,
        // inside 75 s window → agree.
        let pred = prediction(ctaEtaSeconds: 120)
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: Self.pattern,
            latestVehicle: vehicle(pdist: 700),
            history: history(targetSpeed: 5),
            now: Self.now
        )

        #expect(result.verdict == .agree)
        let blendedEta = result.prediction.arrivalAt.timeIntervalSince(Self.now)
        // 0.68 * 120 + 0.32 * 92 = 81.6 + 29.44 = 111.04
        #expect(abs(blendedEta - 111.04) < 1.0)
    }

    @Test("CTA says DUE but geometry says 5 min → trust geometry more")
    func blendDisagreeGhostShape() {
        // CTA ETA 60 s (DUE). Vehicle at pdist 0 of stop 457 (pdist 1160)
        // → remaining 1160 ft. Speed 5 ft/s → geometry ETA 232 s. |Δ| =
        // 172 s, outside window, AND cta <= 90 and geometry > 180 → cta
        // weight 0.25.
        let pred = prediction(ctaEtaSeconds: 60)
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: Self.pattern,
            latestVehicle: vehicle(pdist: 0),
            history: history(targetSpeed: 5),
            now: Self.now
        )

        #expect(result.verdict == .disagree)
        let blendedEta = result.prediction.arrivalAt.timeIntervalSince(Self.now)
        // 0.25 * 60 + 0.75 * 232 = 15 + 174 = 189
        #expect(abs(blendedEta - 189) < 1.5)
    }

    @Test("No history → no blend, prediction passes through unchanged")
    func noHistoryNoBlend() {
        let pred = prediction(ctaEtaSeconds: 120)
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: Self.pattern,
            latestVehicle: vehicle(pdist: 700),
            history: [],
            now: Self.now
        )
        #expect(result.verdict == .noBlend)
        #expect(result.prediction.arrivalAt == pred.arrivalAt)
    }

    @Test("No pattern → no blend")
    func noPatternNoBlend() {
        let pred = prediction(ctaEtaSeconds: 120)
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: nil,
            latestVehicle: vehicle(pdist: 700),
            history: history(targetSpeed: 5),
            now: Self.now
        )
        #expect(result.verdict == .noBlend)
        #expect(result.prediction.arrivalAt == pred.arrivalAt)
    }

    @Test("Vehicle past the stop on pattern → no blend (scorer abstains)")
    func crossedStopNoBlend() {
        let pred = prediction(ctaEtaSeconds: 120)
        // pdist 2050 vs stop 457 (1160) → remaining = -890 ft, well below
        // the -50 ft threshold.
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: Self.pattern,
            latestVehicle: vehicle(pdist: 2050),
            history: history(targetSpeed: 5),
            now: Self.now
        )
        #expect(result.verdict == .noBlend)
        #expect(result.prediction.arrivalAt == pred.arrivalAt)
    }

    @Test("Vehicle stopped (no speed sample) → no blend")
    func noSpeedSampleNoBlend() {
        let pred = prediction(ctaEtaSeconds: 120)
        // pdist hasn't moved across history.
        let stalled: [BusVehicleHistorySample] = [
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-60),
                  patternId: 4042, patternDistanceFeet: 500),
            .init(vehicleId: "1234", observedAt: Self.now.addingTimeInterval(-30),
                  patternId: 4042, patternDistanceFeet: 500),
        ]
        let result = BusGeometryBlender.blend(
            prediction: pred,
            matchedPattern: Self.pattern,
            latestVehicle: vehicle(pdist: 500),
            history: stalled,
            now: Self.now
        )
        #expect(result.verdict == .noBlend)
    }

    @Test("blendAll preserves order and only blends matching predictions")
    func blendAllPreservesOrder() {
        let pA = prediction(stopId: 457, ctaEtaSeconds: 120)
        let pB = prediction(stopId: 458, ctaEtaSeconds: 240)
        let pNoMatch = BusPrediction(
            id: "other", route: "22", routeName: "22",
            vehicleId: "9999", stopId: 999, stopName: "x",
            destinationName: "y", directionName: "Northbound",
            generatedAt: Self.now, arrivalAt: Self.now.addingTimeInterval(180),
            isDelayed: false, isApproaching: false
        )

        let result = BusGeometryBlender.blendAll(
            [pA, pB, pNoMatch],
            vehicles: [vehicle(pdist: 700)],
            patterns: [Self.pattern],
            history: ["1234": history(targetSpeed: 5)],
            now: Self.now
        )

        #expect(result.map(\.id) == [pA.id, pB.id, "other"])
        // pNoMatch has no matching vehicle → arrivalAt unchanged.
        #expect(result[2].arrivalAt == pNoMatch.arrivalAt)
    }
}
