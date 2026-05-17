import Foundation
import TransitModels

/// Per-prediction reliability assessment. Drives ranking, filtering, and
/// styling at display time — never user-facing copy, per the project's
/// invisible-predictions rule. See `docs/BUS_RELIABILITY.md`.
public struct BusArrivalReliability: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        /// Strong evidence; render normally.
        case highConfidence
        /// Acceptable evidence; render normally.
        case mediumConfidence
        /// Weak evidence; render with muted styling.
        case lowConfidence
        /// Evidence contradicts the prediction; render muted or hide.
        case unreliable
        /// Abstain; remove from the displayed list entirely.
        case doNotDisplay
    }

    public enum ReasonCode: String, Sendable, Hashable {
        case vehicleFresh = "VEHICLE_FRESH"
        case vehicleStale = "VEHICLE_STALE"
        case vehicleNotFound = "VEHICLE_NOT_FOUND"
        case vehicleNearStopAtDue = "VEHICLE_NEAR_STOP_AT_DUE"
        case dueButVehicleNotNearStop = "DUE_BUT_VEHICLE_NOT_NEAR_STOP"
        case routeMatch = "ROUTE_MATCH"
        case routeMismatch = "ROUTE_MISMATCH"
        case predictionFresh = "PREDICTION_FRESH"
        case predictionStale = "PREDICTION_STALE"
        case delayedFlagged = "DLY_TRUE"
        case stopLocationUnknown = "STOP_LOCATION_UNKNOWN"
        case arrivalAlreadyPassed = "ARRIVAL_ALREADY_PASSED"
    }

    public let id: String
    public let state: State
    /// Continuous 0–1 score used for ranking ties and the debug surface only.
    /// Not exposed to riders as a percentage.
    public let score: Double
    public let reasonCodes: [ReasonCode]

    public init(
        id: String,
        state: State,
        score: Double,
        reasonCodes: [ReasonCode]
    ) {
        self.id = id
        self.state = state
        self.score = min(max(score, 0), 1)
        self.reasonCodes = reasonCodes
    }

    /// True when the prediction should appear on the rider's screen at all.
    public var isDisplayable: Bool { state != .doNotDisplay }

    /// True when the prediction should appear but in a muted style — caller
    /// decides what "muted" means visually.
    public var needsMutedStyling: Bool {
        state == .lowConfidence || state == .unreliable
    }
}

/// Pure scorer over a `BusPrediction` plus matched `VehiclePosition` and stop
/// coordinates. No I/O. Inputs are owned by the caller — fetch and cache live
/// in `RefreshCoordinator`; this layer just decides what's safe to show.
///
/// Default thresholds come from the CTA-tight-arrivals prototype's soak data
/// (60/120s freshness, 350m DUE-but-far cutoff). They are public so phase 4
/// calibration can tune them per route once residual quantiles exist.
public struct BusReliabilityScorer: Sendable {
    public var freshVehicleAge: TimeInterval
    public var staleVehicleAge: TimeInterval
    public var freshPredictionAge: TimeInterval
    public var stalePredictionAge: TimeInterval
    public var dueWindow: TimeInterval
    public var nearStopMeters: Double
    public var farFromStopMeters: Double

    public init(
        freshVehicleAge: TimeInterval = 60,
        staleVehicleAge: TimeInterval = 120,
        freshPredictionAge: TimeInterval = 60,
        stalePredictionAge: TimeInterval = 120,
        dueWindow: TimeInterval = 90,
        nearStopMeters: Double = 300,
        farFromStopMeters: Double = 350
    ) {
        self.freshVehicleAge = freshVehicleAge
        self.staleVehicleAge = staleVehicleAge
        self.freshPredictionAge = freshPredictionAge
        self.stalePredictionAge = stalePredictionAge
        self.dueWindow = dueWindow
        self.nearStopMeters = nearStopMeters
        self.farFromStopMeters = farFromStopMeters
    }

    /// Score every prediction in `predictions` against the latest vehicles
    /// and the supplied stop-location lookup. Returns a map keyed by
    /// `BusPrediction.id`.
    public func assessments(
        for predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        stopLocation: (BusPrediction) -> (lat: Double, lon: Double)?,
        now: Date = .now
    ) -> [String: BusArrivalReliability] {
        let busVehicleById: [String: VehiclePosition] = Dictionary(
            predictions.compactMap { pred -> (String, VehiclePosition)? in
                guard
                    let match = vehicles.first(where: {
                        $0.mode == .bus && $0.id == pred.vehicleId
                    })
                else { return nil }
                return (pred.vehicleId, match)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(uniqueKeysWithValues: predictions.map { pred in
            let reliability = assessment(
                for: pred,
                vehicle: busVehicleById[pred.vehicleId],
                stopLocation: stopLocation(pred),
                now: now
            )
            return (pred.id, reliability)
        })
    }

    /// Convenience that scores every prediction against `BusStopCatalog` for
    /// stop locations and drops `doNotDisplay` results. Used by callers that
    /// just want the displayable list without managing the assessment map
    /// themselves.
    public static func displayablePredictions(
        from predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        scorer: BusReliabilityScorer = BusReliabilityScorer(),
        now: Date = .now
    ) -> [BusPrediction] {
        let assessments = scorer.catalogedAssessments(
            for: predictions,
            vehicles: vehicles,
            now: now
        )
        return predictions.filter { assessments[$0.id]?.isDisplayable ?? true }
    }

    /// `assessments(for:...)` variant that resolves stop locations via
    /// `BusStopCatalog`. Returned map is keyed by `BusPrediction.id`.
    public func catalogedAssessments(
        for predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        now: Date = .now
    ) -> [String: BusArrivalReliability] {
        assessments(
            for: predictions,
            vehicles: vehicles,
            stopLocation: { pred in
                BusStopCatalog.stops(onRoute: pred.route)
                    .first(where: { $0.id == pred.stopId })
                    .map { (lat: $0.latitude, lon: $0.longitude) }
            },
            now: now
        )
    }

    /// Score a single prediction. `vehicle` is the latest matched bus
    /// observation for `prediction.vehicleId`, or nil when none is in the
    /// current feed (the ghost-bus case).
    public func assessment(
        for prediction: BusPrediction,
        vehicle: VehiclePosition?,
        stopLocation: (lat: Double, lon: Double)?,
        now: Date = .now
    ) -> BusArrivalReliability {
        var reasons: [BusArrivalReliability.ReasonCode] = []
        var score = 0.52
        var abstain = false

        // CTA already says this bus came and went. Even with perfect data
        // we shouldn't continue showing it as arriving.
        let etaSeconds = prediction.arrivalAt.timeIntervalSince(now)
        if etaSeconds < -60 {
            reasons.append(.arrivalAlreadyPassed)
            return BusArrivalReliability(
                id: prediction.id,
                state: .doNotDisplay,
                score: 0,
                reasonCodes: reasons
            )
        }

        let predictionAge = max(0, now.timeIntervalSince(prediction.generatedAt))
        if predictionAge <= freshPredictionAge {
            reasons.append(.predictionFresh)
            score += 0.06
        } else if predictionAge > stalePredictionAge {
            reasons.append(.predictionStale)
            score -= 0.18
        }

        if prediction.isDelayed {
            reasons.append(.delayedFlagged)
            score -= 0.04
        }

        if let vehicle {
            let vehicleAge = max(0, now.timeIntervalSince(vehicle.observedAt))
            if vehicleAge <= freshVehicleAge {
                reasons.append(.vehicleFresh)
                score += 0.18
            } else if vehicleAge > staleVehicleAge {
                reasons.append(.vehicleStale)
                score -= 0.30
            }

            if vehicle.route.caseInsensitiveCompare(prediction.route) == .orderedSame {
                reasons.append(.routeMatch)
                score += 0.05
            } else {
                reasons.append(.routeMismatch)
                score -= 0.20
            }

            if let stopLocation, vehicleAge <= staleVehicleAge {
                let distance = Distance.meters(
                    from: (vehicle.latitude, vehicle.longitude),
                    to: stopLocation
                )
                let dueSoon = etaSeconds <= dueWindow

                if dueSoon, distance > farFromStopMeters {
                    // The user's #65 Grand & McClurg failure mode: CTA says
                    // a minute, vehicle is far away. Hide it rather than
                    // let the user wait for a bus that isn't coming.
                    reasons.append(.dueButVehicleNotNearStop)
                    abstain = true
                    score -= 0.40
                } else if dueSoon, distance <= nearStopMeters {
                    reasons.append(.vehicleNearStopAtDue)
                    score += 0.15
                }
            } else if stopLocation == nil {
                reasons.append(.stopLocationUnknown)
            }
        } else {
            // No matching vehicle in the feed at all. Strong negative when
            // CTA claims the bus is imminent — that's exactly the ghost
            // case. Less severe when the bus is "in 8 minutes" because
            // BusTime can emit predictions before tracking the assigned
            // vehicle.
            reasons.append(.vehicleNotFound)
            if etaSeconds <= dueWindow {
                abstain = true
                score -= 0.55
            } else if etaSeconds <= 5 * 60 {
                score -= 0.30
            } else {
                score -= 0.15
            }
        }

        let clamped = min(max(score, 0), 1)
        let state: BusArrivalReliability.State = {
            if abstain { return .doNotDisplay }
            if clamped >= 0.78 { return .highConfidence }
            if clamped >= 0.60 { return .mediumConfidence }
            if clamped >= 0.40 { return .lowConfidence }
            return .unreliable
        }()

        return BusArrivalReliability(
            id: prediction.id,
            state: state,
            score: clamped,
            reasonCodes: reasons
        )
    }
}
