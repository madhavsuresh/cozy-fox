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
        case detourActive = "DETOUR_ACTIVE"
        case stopRemovedByDetour = "STOP_REMOVED_BY_DETOUR"
        case patternMatch = "PATTERN_MATCH"
        case patternMismatch = "PATTERN_MISMATCH"
        case pdistCrossedStop = "PDIST_CROSSED_STOP"
        case gpsOnExpectedPattern = "GPS_ON_EXPECTED_PATTERN"
        case gpsOffExpectedPattern = "GPS_OFF_EXPECTED_PATTERN"
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
    /// Along-pattern distance under which a DUE prediction looks plausible.
    /// 800 ft ≈ 2 short Chicago blocks. When pattern data is available,
    /// this replaces the meter-based haversine check for the DUE-but-near
    /// boost.
    public var nearStopFeet: Double
    /// Along-pattern distance over which a DUE prediction looks like a
    /// ghost. 1000 ft ≈ 3 blocks. Pattern distance follows the route, so
    /// it's much sharper than haversine: a bus 1000 ft *along the pattern*
    /// is genuinely 1000 ft of stops-and-traffic away.
    public var farFromStopFeet: Double
    /// Negative remaining feet at which we treat the vehicle as having
    /// already crossed the stop. Tiny slop because buses sometimes pull
    /// up *just past* the sign.
    public var crossedStopFeet: Double
    /// Cross-track distance (meters) past which a vehicle's GPS is
    /// considered off-pattern. The map-match still tries; we just
    /// downgrade the prediction's reliability.
    public var maxOnPatternCrossTrackMeters: Double

    public init(
        freshVehicleAge: TimeInterval = 60,
        staleVehicleAge: TimeInterval = 120,
        freshPredictionAge: TimeInterval = 60,
        stalePredictionAge: TimeInterval = 120,
        dueWindow: TimeInterval = 90,
        nearStopMeters: Double = 300,
        farFromStopMeters: Double = 350,
        nearStopFeet: Double = 800,
        farFromStopFeet: Double = 1_000,
        crossedStopFeet: Double = -50,
        maxOnPatternCrossTrackMeters: Double = 100
    ) {
        self.freshVehicleAge = freshVehicleAge
        self.staleVehicleAge = staleVehicleAge
        self.freshPredictionAge = freshPredictionAge
        self.stalePredictionAge = stalePredictionAge
        self.dueWindow = dueWindow
        self.nearStopMeters = nearStopMeters
        self.farFromStopMeters = farFromStopMeters
        self.nearStopFeet = nearStopFeet
        self.farFromStopFeet = farFromStopFeet
        self.crossedStopFeet = crossedStopFeet
        self.maxOnPatternCrossTrackMeters = maxOnPatternCrossTrackMeters
    }

    /// Score every prediction in `predictions` against the latest vehicles
    /// and the supplied stop-location lookup. Returns a map keyed by
    /// `BusPrediction.id`.
    public func assessments(
        for predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        stopLocation: (BusPrediction) -> (lat: Double, lon: Double)?,
        activeDetours: [BusDetour] = [],
        patterns: [BusPattern] = [],
        stopDetourStates: [BusStopDetourState] = [],
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
                activeDetours: activeDetours,
                patterns: patterns,
                stopDetourState: stopDetourStates.first { $0.stopId == pred.stopId },
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
        activeDetours: [BusDetour] = [],
        patterns: [BusPattern] = [],
        stopDetourStates: [BusStopDetourState] = [],
        scorer: BusReliabilityScorer = BusReliabilityScorer(),
        now: Date = .now
    ) -> [BusPrediction] {
        let assessments = scorer.catalogedAssessments(
            for: predictions,
            vehicles: vehicles,
            activeDetours: activeDetours,
            patterns: patterns,
            stopDetourStates: stopDetourStates,
            now: now
        )
        return predictions.filter { assessments[$0.id]?.isDisplayable ?? true }
    }

    /// `assessments(for:...)` variant that resolves stop locations via
    /// `BusStopCatalog`. Returned map is keyed by `BusPrediction.id`.
    public func catalogedAssessments(
        for predictions: [BusPrediction],
        vehicles: [VehiclePosition],
        activeDetours: [BusDetour] = [],
        patterns: [BusPattern] = [],
        stopDetourStates: [BusStopDetourState] = [],
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
            activeDetours: activeDetours,
            patterns: patterns,
            stopDetourStates: stopDetourStates,
            now: now
        )
    }

    /// Score a single prediction. `vehicle` is the latest matched bus
    /// observation for `prediction.vehicleId`, or nil when none is in the
    /// current feed (the ghost-bus case). `activeDetours` is the cached
    /// `getdetours` snapshot — pass an empty array when detour state is
    /// unknown. `patterns` is the cached `getpatterns` snapshot — when
    /// the matching pattern is present and the vehicle has a `pdist`, the
    /// scorer uses along-pattern distance for the DUE-but-far check and
    /// can detect already-crossed-stop.
    public func assessment(
        for prediction: BusPrediction,
        vehicle: VehiclePosition?,
        stopLocation: (lat: Double, lon: Double)?,
        activeDetours: [BusDetour] = [],
        patterns: [BusPattern] = [],
        stopDetourState: BusStopDetourState? = nil,
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

        // Phase 2b: stop-removed-by-detour is a hard abstain. The CTA
        // server's predictions usually disappear once a detour engages,
        // but in the transition window they can hang around — and a
        // rider standing at a removed stop is one of the worst failure
        // modes we can hide.
        if let stopDetourState, stopDetourState.isRemovedBy(activeDetours: activeDetours) {
            reasons.append(.stopRemovedByDetour)
            return BusArrivalReliability(
                id: prediction.id,
                state: .doNotDisplay,
                score: 0,
                reasonCodes: reasons
            )
        }

        // Active detour on the same (route, direction) — soft warn. We
        // can know from `getdetours` that the route is detoured, but
        // (absent the stop-detour state above) we don't know whether
        // *this stop* is skipped. Downgrade enough to drop a borderline
        // high-confidence into medium so the rider's expectations are
        // shaped.
        let detourHit = activeDetours.contains { detour in
            detour.affects(route: prediction.route, direction: prediction.directionName, at: now)
        }
        if detourHit {
            reasons.append(.detourActive)
            score -= 0.10
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

            // Pattern geometry (when available) gives a sharper signal
            // than haversine because it follows the route, not crow-fly.
            // We try pattern-based scoring first and fall back to
            // haversine when patterns are missing or the vehicle has no
            // pdist yet.
            var patternResolved = false
            let pattern = BusPatternGeometry.pattern(
                for: vehicle.patternId,
                route: vehicle.route,
                directionName: prediction.directionName,
                in: patterns
            )

            if let pattern, let remaining = BusPatternGeometry.remainingFeetAlongPattern(
                vehiclePatternDistance: vehicle.patternDistanceFeet,
                stopId: prediction.stopId,
                pattern: pattern
            ) {
                patternResolved = true
                reasons.append(.patternMatch)
                score += 0.05

                if let mapMatch = BusPatternGeometry.mapMatch(
                    pattern,
                    lat: vehicle.latitude,
                    lon: vehicle.longitude
                ) {
                    if mapMatch.crossTrackMeters > maxOnPatternCrossTrackMeters {
                        reasons.append(.gpsOffExpectedPattern)
                        score -= 0.12
                    } else {
                        reasons.append(.gpsOnExpectedPattern)
                        score += 0.04
                    }
                }

                if remaining < crossedStopFeet {
                    // Bus pdist is meaningfully past the stop's pdist.
                    // Don't keep counting down to an arrival that already
                    // happened — abstain. (`A` predictions only; `D`
                    // departure-from-terminal predictions can sit past
                    // the stop while a vehicle layovers.)
                    reasons.append(.pdistCrossedStop)
                    abstain = true
                    score -= 0.55
                } else if etaSeconds <= dueWindow, remaining > farFromStopFeet {
                    // The pattern-aware version of the #65 case: CTA
                    // says DUE but pdist says the vehicle is still well
                    // upstream of the stop. Strong abstain.
                    reasons.append(.dueButVehicleNotNearStop)
                    abstain = true
                    score -= 0.40
                } else if etaSeconds <= dueWindow, remaining <= nearStopFeet {
                    reasons.append(.vehicleNearStopAtDue)
                    score += 0.15
                }
            } else if !patterns.isEmpty,
                      vehicle.patternId != nil,
                      pattern == nil {
                // Patterns are loaded but none matched this vehicle's
                // pid. Could be a detour variant we haven't cached yet
                // or a stale pid. Note it but don't penalize hard —
                // haversine fallback below picks up the load.
                reasons.append(.patternMismatch)
                score -= 0.06
            }

            if let stopLocation, vehicleAge <= staleVehicleAge, !patternResolved {
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
            } else if stopLocation == nil, !patternResolved {
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
