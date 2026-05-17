import Foundation
import TransitModels

/// Phase 3b: combines CTA's predicted arrival with an independent geometry
/// ETA derived from the vehicle's recent along-pattern progress. Mirrors
/// the `cta_weight` blending logic in the cta-tight-arrivals prototype:
///
/// - If both estimates agree (Δ ≤ 75 s), output a confident weighted
///   average leaning slightly toward CTA.
/// - If they disagree, output a re-weighted average that trusts geometry
///   more when CTA says DUE but geometry says we're still minutes out
///   (the ghost shape), and trusts CTA more when geometry has no recent
///   speed sample at all.
///
/// Pure function; speed estimation, pattern lookup, and blending are all
/// done from the inputs. Returns a new `BusPrediction` with a shifted
/// `arrivalAt`, plus a verdict describing what happened.
public enum BusGeometryBlender {
    public enum Verdict: String, Sendable, Hashable {
        /// CTA and geometry agreed within tolerance; blended toward CTA.
        case agree
        /// CTA and geometry disagreed; blend re-weighted.
        case disagree
        /// No geometry estimate available — prediction passes through.
        case noBlend
    }

    public struct Result: Sendable {
        public let prediction: BusPrediction
        public let verdict: Verdict
        public let ctaEtaSeconds: Double
        public let geometryEtaSeconds: Double?
        public let speedFtPerSecond: Double?
        public let appliedShiftSeconds: Double
    }

    /// Default thresholds match the prototype's defaults.
    public static let agreeWindowSeconds: Double = 75
    public static let dueWindowSeconds: Double = 90
    public static let crossedStopFeet: Double = -50

    public static func blend(
        prediction: BusPrediction,
        matchedPattern: BusPattern?,
        latestVehicle: VehiclePosition?,
        history: [BusVehicleHistorySample],
        now: Date = .now
    ) -> Result {
        let ctaEtaSeconds = prediction.arrivalAt.timeIntervalSince(now)

        guard
            let pattern = matchedPattern,
            let vehicle = latestVehicle,
            let vehiclePdist = vehicle.patternDistanceFeet,
            let stopPdist = pattern.patternDistanceForStop(prediction.stopId)
        else {
            return Result(
                prediction: prediction,
                verdict: .noBlend,
                ctaEtaSeconds: ctaEtaSeconds,
                geometryEtaSeconds: nil,
                speedFtPerSecond: nil,
                appliedShiftSeconds: 0
            )
        }

        let remainingFt = stopPdist - vehiclePdist
        // Already-crossed stops are handled by the scorer's
        // pdistCrossedStop abstain — the blender skips them too rather
        // than emit a meaningless 0-second ETA.
        guard remainingFt >= crossedStopFeet else {
            return Result(
                prediction: prediction,
                verdict: .noBlend,
                ctaEtaSeconds: ctaEtaSeconds,
                geometryEtaSeconds: nil,
                speedFtPerSecond: nil,
                appliedShiftSeconds: 0
            )
        }

        let onPattern = history.filter { $0.patternId == vehicle.patternId }
        guard let speed = robustMedianSpeedFtPerSecond(onPattern) else {
            return Result(
                prediction: prediction,
                verdict: .noBlend,
                ctaEtaSeconds: ctaEtaSeconds,
                geometryEtaSeconds: nil,
                speedFtPerSecond: nil,
                appliedShiftSeconds: 0
            )
        }

        let geometryEta = max(0, remainingFt) / speed
        let disagreement = abs(ctaEtaSeconds - geometryEta)
        let blendedEta: Double
        let verdict: Verdict
        if disagreement <= agreeWindowSeconds {
            blendedEta = 0.68 * ctaEtaSeconds + 0.32 * geometryEta
            verdict = .agree
        } else {
            // Default trust slightly toward CTA. Two adjustments:
            // - DUE-but-geometry-still-far: weight CTA way down. This is
            //   the ghost shape the user wants caught.
            // - No-speed-sample case is already handled above, so we
            //   always have geometry here when disagreement > window.
            var ctaWeight = 0.55
            if ctaEtaSeconds <= dueWindowSeconds, geometryEta > 180 {
                ctaWeight = 0.25
            }
            blendedEta = ctaWeight * ctaEtaSeconds + (1 - ctaWeight) * geometryEta
            verdict = .disagree
        }

        let shifted = BusPrediction(
            id: prediction.id,
            route: prediction.route,
            routeName: prediction.routeName,
            vehicleId: prediction.vehicleId,
            stopId: prediction.stopId,
            stopName: prediction.stopName,
            destinationName: prediction.destinationName,
            directionName: prediction.directionName,
            generatedAt: prediction.generatedAt,
            arrivalAt: now.addingTimeInterval(max(0, blendedEta)),
            isDelayed: prediction.isDelayed,
            isApproaching: prediction.isApproaching
        )

        return Result(
            prediction: shifted,
            verdict: verdict,
            ctaEtaSeconds: ctaEtaSeconds,
            geometryEtaSeconds: geometryEta,
            speedFtPerSecond: speed,
            appliedShiftSeconds: blendedEta - ctaEtaSeconds
        )
    }

    /// One-shot helper that runs blend over a prediction list. Lookups for
    /// pattern + latest vehicle + history are done per-prediction. Used by
    /// the dashboard / live-activity pipeline.
    public static func blendAll(
        _ predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        patterns: [BusPattern],
        history: [String: [BusVehicleHistorySample]],
        now: Date = .now
    ) -> [BusPrediction] {
        predictions.map { pred in
            let matchedVehicle = vehicles.first {
                $0.mode == .bus && $0.id == pred.vehicleId
            }
            let matchedPattern = BusPatternGeometry.pattern(
                for: matchedVehicle?.patternId,
                route: pred.route,
                directionName: pred.directionName,
                in: patterns
            )
            return BusGeometryBlender.blend(
                prediction: pred,
                matchedPattern: matchedPattern,
                latestVehicle: matchedVehicle,
                history: history[pred.vehicleId] ?? [],
                now: now
            ).prediction
        }
    }

    // MARK: - Internal

    /// Sanity bounds for a bus speed in feet per second. 1 ft/s ≈ 0.7 mph
    /// (stop dwell or crawling); 90 ft/s ≈ 61 mph (highway segment).
    /// Outside these bounds usually means quantized pdist, a vehicle
    /// reassignment, or telemetry weirdness — drop the sample.
    private static let minReasonableSpeed: Double = 1
    private static let maxReasonableSpeed: Double = 90

    /// Median of forward-progress segment speeds. Drops zero / negative
    /// deltas and out-of-bounds samples so a single hiccup doesn't poison
    /// the estimate.
    static func robustMedianSpeedFtPerSecond(
        _ history: [BusVehicleHistorySample]
    ) -> Double? {
        let sorted = history.sorted { $0.observedAt < $1.observedAt }
        var speeds: [Double] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard let p0 = a.patternDistanceFeet,
                  let p1 = b.patternDistanceFeet else { continue }
            let dt = b.observedAt.timeIntervalSince(a.observedAt)
            guard dt > 0 else { continue }
            let dp = p1 - p0
            guard dp > 0 else { continue }
            let speed = dp / dt
            guard speed >= minReasonableSpeed, speed <= maxReasonableSpeed else { continue }
            speeds.append(speed)
        }
        guard !speeds.isEmpty else { return nil }
        let s = speeds.sorted()
        if s.count.isMultiple(of: 2) {
            let mid = s.count / 2
            return (s[mid - 1] + s[mid]) / 2
        }
        return s[s.count / 2]
    }
}
