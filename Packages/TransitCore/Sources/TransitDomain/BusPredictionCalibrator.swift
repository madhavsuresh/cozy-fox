import Foundation
import TransitModels

/// Applies the personal q50 shift to a `BusPrediction` using whatever
/// `BusResidualQuantileBin` matches its stratum. The shift lives in seconds
/// and is added to `arrivalAt` — so a positive q50 (CTA tends to be early
/// on this stratum) bumps the displayed minutes up by ~q50/60.
///
/// Pure function over a `Calendar`. No I/O, no async. Bins come from the
/// snapshot the AppViewModel mirrors out of `TransitStore`.
public enum BusPredictionCalibrator {
    /// Default minimum sample count before we'll trust a bin's q50. Below
    /// this we step to a coarser stratum rather than apply a single-sample
    /// "calibration."
    public static let defaultMinSamples = 5

    /// The fallback hierarchy from most-specific to least. Each level drops
    /// one dimension of the bin key.
    public enum Stratum: Sendable, Hashable {
        case exact                  // (route, direction, stopId, horizon, hourOfWeek)
        case droppedHourOfWeek      // (route, direction, stopId, horizon)
        case droppedDirection       // (route, stopId, horizon)
        case droppedStopId          // (route, horizon)
    }

    public struct CalibrationResult: Sendable, Hashable {
        public let prediction: BusPrediction
        public let appliedShiftSeconds: Double
        public let stratum: Stratum?
        public let sampleCount: Int

        public var isCalibrated: Bool { stratum != nil }
    }

    /// Returns the calibrated prediction (with `arrivalAt` shifted) plus
    /// metadata about which stratum drove the shift. When no usable bin is
    /// found, returns the prediction unchanged and `stratum == nil`.
    public static func calibrate(
        _ prediction: BusPrediction,
        using bins: [BusResidualQuantileBin],
        calendar: Calendar,
        minSamples: Int = defaultMinSamples
    ) -> CalibrationResult {
        // Read hour-of-week against the prediction's *arrival* time so the
        // bin stratum matches what the residual recorder writes (see
        // `ArrivalGrader.ingestPositions` in the app target).
        let hourOfWeek = BusHourOfWeek.value(for: prediction.arrivalAt, calendar: calendar)
        let horizonSeconds = max(0, prediction.arrivalAt.timeIntervalSince(prediction.generatedAt))
        let horizon = BusHorizonBucket.bucket(for: horizonSeconds)

        // Build cheap predicate filters once, then walk the fallback ladder.
        func bestMatch(_ predicate: (BusResidualQuantileBin) -> Bool) -> BusResidualQuantileBin? {
            // Within a stratum, prefer the highest sample count (most data).
            // Ties broken by most recent update so a freshly retrained bin
            // wins over a stale one with the same count.
            return bins.filter(predicate)
                .filter { $0.sampleCount >= minSamples }
                .max { lhs, rhs in
                    if lhs.sampleCount != rhs.sampleCount {
                        return lhs.sampleCount < rhs.sampleCount
                    }
                    return lhs.lastUpdated < rhs.lastUpdated
                }
        }

        let route = prediction.route
        let direction = prediction.directionName
        let stopId = prediction.stopId

        let ladder: [(Stratum, (BusResidualQuantileBin) -> Bool)] = [
            (.exact, { bin in
                bin.route == route
                    && bin.directionName == direction
                    && bin.stopId == stopId
                    && bin.horizonBucket == horizon
                    && bin.hourOfWeek == hourOfWeek
            }),
            (.droppedHourOfWeek, { bin in
                bin.route == route
                    && bin.directionName == direction
                    && bin.stopId == stopId
                    && bin.horizonBucket == horizon
            }),
            (.droppedDirection, { bin in
                bin.route == route
                    && bin.stopId == stopId
                    && bin.horizonBucket == horizon
            }),
            (.droppedStopId, { bin in
                bin.route == route
                    && bin.horizonBucket == horizon
            }),
        ]

        for (stratum, predicate) in ladder {
            guard let match = bestMatch(predicate) else { continue }
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
                arrivalAt: prediction.arrivalAt.addingTimeInterval(match.q50Seconds),
                isDelayed: prediction.isDelayed,
                isApproaching: prediction.isApproaching
            )
            return CalibrationResult(
                prediction: shifted,
                appliedShiftSeconds: match.q50Seconds,
                stratum: stratum,
                sampleCount: match.sampleCount
            )
        }

        return CalibrationResult(
            prediction: prediction,
            appliedShiftSeconds: 0,
            stratum: nil,
            sampleCount: 0
        )
    }

    /// Convenience for filtering pipelines: returns predictions with
    /// calibration applied, in input order. Predictions that didn't match
    /// any bin pass through unchanged.
    public static func calibrateAll(
        _ predictions: [BusPrediction],
        using bins: [BusResidualQuantileBin],
        calendar: Calendar = .currentChicago,
        minSamples: Int = defaultMinSamples
    ) -> [BusPrediction] {
        predictions.map {
            calibrate($0, using: bins, calendar: calendar, minSamples: minSamples).prediction
        }
    }

    /// One-shot: scores reliability, calibrates the medium/high-confidence
    /// rows, drops `doNotDisplay`. Used by glance surfaces that don't keep
    /// the reliability map separately. See `BusReliabilityScorer` for the
    /// underlying scorer config.
    public static func displayableCalibratedPredictions(
        from predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        activeDetours: [BusDetour] = [],
        patterns: [BusPattern] = [],
        bins: [BusResidualQuantileBin] = [],
        scorer: BusReliabilityScorer = BusReliabilityScorer(),
        calendar: Calendar = .currentChicago,
        minSamples: Int = defaultMinSamples,
        now: Date = .now
    ) -> [BusPrediction] {
        let reliabilities = scorer.catalogedAssessments(
            for: predictions,
            vehicles: vehicles,
            activeDetours: activeDetours,
            patterns: patterns,
            now: now
        )
        return predictions.compactMap { pred -> BusPrediction? in
            let reliability = reliabilities[pred.id]
            guard reliability?.isDisplayable ?? true else { return nil }
            switch reliability?.state {
            case .highConfidence, .mediumConfidence:
                return BusPredictionCalibrator.calibrate(
                    pred,
                    using: bins,
                    calendar: calendar,
                    minSamples: minSamples
                ).prediction
            default:
                return pred
            }
        }
    }
}

public extension Calendar {
    /// Chicago-local gregorian calendar with POSIX locale — matches the
    /// rest of the domain layer (see `SystemClock`).
    static var currentChicago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }
}
