import Foundation
import TransitModels

/// Per-arrival reliability assessment for CTA trains. Mirror of
/// `BusArrivalReliability` so the two modes share a mental model and
/// the dot-strip badge vocabulary (green ✓ / muted ✓ / gold ? / red ! /
/// red X). Drives ranking, filtering, and styling at display time —
/// never user-facing copy, per the project's invisible-predictions rule.
public struct TrainArrivalReliability: Sendable, Hashable, Identifiable {
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
        // Freshness — same shape as bus.
        case vehicleFresh = "VEHICLE_FRESH"
        case vehicleStale = "VEHICLE_STALE"
        case vehicleNotFound = "VEHICLE_NOT_FOUND"
        case predictionFresh = "PREDICTION_FRESH"
        case predictionStale = "PREDICTION_STALE"

        // Match quality.
        case runNumberMatch = "RUN_NUMBER_MATCH"
        case lineMatch = "LINE_MATCH"
        case lineMismatch = "LINE_MISMATCH"

        // Geometry. The bus side splits this further with pattern
        // distance; trains only have station lat/lon, so the haversine
        // bucket is all we get here. Tighter thresholds than buses
        // because trains move faster (the bus DUE-but-far at 350m
        // catches the #65 case; a Red Line train doing 30 mph between
        // platforms covers 350m in 25 seconds — too short to be a
        // useful far-from-stop signal).
        case vehicleNearStationAtDue = "VEHICLE_NEAR_STATION_AT_DUE"
        case dueButVehicleNotNearStation = "DUE_BUT_VEHICLE_NOT_NEAR_STATION"
        case stationLocationUnknown = "STATION_LOCATION_UNKNOWN"
        /// Train-specific positive signal: the matched vehicle's
        /// `nextStpId` equals the arrival's `stopId`. Means CTA is
        /// telling us this exact train is heading to this exact
        /// platform next — the strongest direct corroboration we get
        /// from the positions feed. Only meaningful at small ETA;
        /// for a 10-minute-out arrival the train's `nextStpId` will
        /// rightly be some upstream stop, so we don't penalize
        /// non-matches.
        case nextStopMatchesArrival = "NEXT_STOP_MATCHES_ARRIVAL"

        // Past-due.
        case arrivalAlreadyPassed = "ARRIVAL_ALREADY_PASSED"

        // CTA-side flags. `isApp`/`isFlt`/`isSch` are train-only;
        // `isDly` mirrors the bus's `isDelayed`.
        case delayedFlagged = "DLY_TRUE"
        /// CTA flagged `isApp == "1"` ("this train is right at the
        /// platform"). Soft positive on its own — it's only fully
        /// trustworthy when paired with a fresh, near-station vehicle
        /// (handled separately by `vehicleNearStationAtDue`).
        case approachingFlag = "APP_TRUE"
        /// CTA says `isApp == "1"` but the positions feed has no
        /// matching run. Strong negative — that's the train-specific
        /// ghost signature (the equivalent of the bus DUE-but-far
        /// case at the DUE window).
        case approachingButNoVehicle = "APP_BUT_NO_VEHICLE"
        /// CTA's explicit `isFlt == "1"`: the prediction is faulty.
        /// Closest analog to the bus side's `dyn` non-standard
        /// signal — strong reliability downgrade, but a tracked
        /// nearby vehicle can still pull it back up.
        case faultFlagged = "FLT_TRUE"
        /// CTA's explicit `isSch == "1"`: schedule-only entry, no
        /// live train backs this prediction. Softer than `isFlt` —
        /// the train is still expected per the schedule, just not
        /// being tracked yet.
        case scheduledOnly = "SCH_TRUE"
        /// A high-severity service alert is active on this line.
        /// Soft downgrade — we don't know whether *this* station is
        /// affected, but rider expectations should be shaped. Train
        /// alerts don't decompose into per-stop "removed" flags the
        /// way bus detours do, so we stop at the line level.
        case majorAlertOnLine = "MAJOR_ALERT_ON_LINE"
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

    /// True when the arrival should appear on the rider's screen at all.
    public var isDisplayable: Bool { state != .doNotDisplay }

    /// True when the arrival is visible but its headline number
    /// shouldn't be trusted. Includes `.doNotDisplay` so the
    /// "Show everything" filter level still suppresses BigNumber
    /// on rows we believe are positively wrong.
    public var needsMutedStyling: Bool {
        state == .lowConfidence || state == .unreliable || state == .doNotDisplay
    }
}

/// Pure scorer over an `Arrival` plus matched `VehiclePosition` and
/// station coordinates. No I/O — the caller owns fetching the positions
/// feed and the alerts feed. Mirror of `BusReliabilityScorer`.
///
/// Default thresholds widen a bit relative to buses because trains move
/// faster and update less frequently: 90/180s freshness windows and a
/// 1500m DUE-but-far cutoff. Trains can cover 1.5km between adjacent
/// stations in about a minute on the elevated, so a 90s DUE-window
/// train sitting more than 1500m away is a strong ghost signal.
public struct TrainReliabilityScorer: Sendable {
    public var freshVehicleAge: TimeInterval
    public var staleVehicleAge: TimeInterval
    public var freshPredictionAge: TimeInterval
    public var stalePredictionAge: TimeInterval
    public var dueWindow: TimeInterval
    public var nearStationMeters: Double
    public var farFromStationMeters: Double
    /// ETA cutoff for the `nextStopMatchesArrival` positive signal.
    /// At small ETAs the vehicle's `nextStpId` should equal the
    /// arrival's stop; at larger ETAs it'll naturally point upstream
    /// and a mismatch shouldn't penalize us.
    public var nextStopMatchWindow: TimeInterval

    public init(
        freshVehicleAge: TimeInterval = 90,
        staleVehicleAge: TimeInterval = 180,
        freshPredictionAge: TimeInterval = 90,
        stalePredictionAge: TimeInterval = 180,
        dueWindow: TimeInterval = 90,
        nearStationMeters: Double = 400,
        farFromStationMeters: Double = 1_500,
        nextStopMatchWindow: TimeInterval = 4 * 60
    ) {
        self.freshVehicleAge = freshVehicleAge
        self.staleVehicleAge = staleVehicleAge
        self.freshPredictionAge = freshPredictionAge
        self.stalePredictionAge = stalePredictionAge
        self.dueWindow = dueWindow
        self.nearStationMeters = nearStationMeters
        self.farFromStationMeters = farFromStationMeters
        self.nextStopMatchWindow = nextStopMatchWindow
    }

    /// Score every arrival in `arrivals` against the latest vehicles
    /// and the supplied station-location lookup. Returns a map keyed
    /// by `Arrival.id`.
    public func assessments(
        for arrivals: [Arrival],
        vehiclePositions: [VehiclePosition],
        stationLocation: (Arrival) -> (lat: Double, lon: Double)?,
        alerts: [ServiceAlert] = [],
        now: Date = .now
    ) -> [String: TrainArrivalReliability] {
        Dictionary(uniqueKeysWithValues: arrivals.map { arrival in
            (
                arrival.id,
                assessment(
                    for: arrival,
                    vehicle: matchingVehicle(for: arrival, in: vehiclePositions),
                    stationLocation: stationLocation(arrival),
                    alerts: alerts,
                    now: now
                )
            )
        })
    }

    /// Convenience that resolves station locations via `LStationCatalog`.
    /// Used by callers that just want the scored map without managing
    /// catalog lookups themselves.
    public func catalogedAssessments(
        for arrivals: [Arrival],
        vehiclePositions: [VehiclePosition],
        alerts: [ServiceAlert] = [],
        now: Date = .now
    ) -> [String: TrainArrivalReliability] {
        assessments(
            for: arrivals,
            vehiclePositions: vehiclePositions,
            stationLocation: { arrival in
                LStationCatalog.byId[arrival.stationId].map {
                    (lat: $0.latitude, lon: $0.longitude)
                }
            },
            alerts: alerts,
            now: now
        )
    }

    /// Convenience that scores every arrival and drops `doNotDisplay`
    /// results. Mirror of `BusReliabilityScorer.displayablePredictions`.
    public static func displayableArrivals(
        from arrivals: [Arrival],
        vehiclePositions: [VehiclePosition],
        alerts: [ServiceAlert] = [],
        scorer: TrainReliabilityScorer = TrainReliabilityScorer(),
        now: Date = .now
    ) -> [Arrival] {
        let assessments = scorer.catalogedAssessments(
            for: arrivals,
            vehiclePositions: vehiclePositions,
            alerts: alerts,
            now: now
        )
        return arrivals.filter { assessments[$0.id]?.isDisplayable ?? true }
    }

    /// Score a single arrival. `vehicle` is the latest matched
    /// position for `arrival.runNumber`, or nil when none is in the
    /// current positions feed (the ghost case).
    public func assessment(
        for arrival: Arrival,
        vehicle: VehiclePosition?,
        stationLocation: (lat: Double, lon: Double)?,
        alerts: [ServiceAlert] = [],
        now: Date = .now
    ) -> TrainArrivalReliability {
        var reasons: [TrainArrivalReliability.ReasonCode] = []
        var score = 0.52
        var abstain = false

        // CTA already says this train came and went. Don't keep
        // counting down to it.
        let etaSeconds = arrival.arrivalAt.timeIntervalSince(now)
        if etaSeconds < -60 {
            reasons.append(.arrivalAlreadyPassed)
            return TrainArrivalReliability(
                id: arrival.id,
                state: .doNotDisplay,
                score: 0,
                reasonCodes: reasons
            )
        }

        // High-severity alert on this line — soft warn. The
        // CTAAlertsClient doesn't decompose into per-station
        // "skipped" flags the way the bus `getdetours` payload does,
        // so we stop at the line-level signal. Enough to drop a
        // borderline high-confidence into medium so the rider's
        // expectations are shaped.
        let hasMajorAlert = alerts.contains { alert in
            alert.severity == .high
                && alert.impactedLineColors.contains(arrival.line)
                && alert.isActive(at: now)
        }
        if hasMajorAlert {
            reasons.append(.majorAlertOnLine)
            score -= 0.10
        }

        let predictionAge = max(0, now.timeIntervalSince(arrival.predictedAt))
        if predictionAge <= freshPredictionAge {
            reasons.append(.predictionFresh)
            score += 0.06
        } else if predictionAge > stalePredictionAge {
            reasons.append(.predictionStale)
            score -= 0.18
        }

        if arrival.isDelayed {
            reasons.append(.delayedFlagged)
            score -= 0.04
        }

        // CTA explicitly marked this prediction faulty. Closest train
        // analog to the bus `dyn` non-standard signal — strong
        // downgrade.
        if arrival.isFault {
            reasons.append(.faultFlagged)
            score -= 0.25
        }

        // Schedule-only entry: no live train backs this row. Softer
        // than `isFlt` because the train is still expected to run;
        // we just don't have a position fix to corroborate it.
        if arrival.isScheduled {
            reasons.append(.scheduledOnly)
            score -= 0.15
        }

        if let vehicle {
            reasons.append(.runNumberMatch)

            let vehicleAge = max(0, now.timeIntervalSince(vehicle.observedAt))
            if vehicleAge <= freshVehicleAge {
                reasons.append(.vehicleFresh)
                score += 0.18
            } else if vehicleAge > staleVehicleAge {
                reasons.append(.vehicleStale)
                score -= 0.30
            }

            if vehicle.route.caseInsensitiveCompare(arrival.line.rawValue) == .orderedSame {
                reasons.append(.lineMatch)
                score += 0.05
            } else {
                reasons.append(.lineMismatch)
                score -= 0.20
            }

            // Train-specific corroboration: the live train's "next
            // stop" matches the arrival's platform. Strong positive
            // at small ETAs only — at larger ETAs the train will
            // legitimately be heading to an upstream platform first,
            // and a non-match means nothing.
            if let nextStpId = vehicle.nextStopId,
               nextStpId == arrival.stopId,
               etaSeconds <= nextStopMatchWindow {
                reasons.append(.nextStopMatchesArrival)
                score += 0.10
            }

            // `isApp == "1"` paired with a tracked vehicle is the
            // train-side version of the bus DUE-with-near-stop boost.
            // The geometry check below adds another `+0.15` when the
            // vehicle is also actually close to the station — the
            // two signals stack for the "right here right now" case.
            if arrival.isApproaching {
                reasons.append(.approachingFlag)
                score += 0.06
            }

            if let stationLocation, vehicleAge <= staleVehicleAge {
                let distance = Distance.meters(
                    from: (vehicle.latitude, vehicle.longitude),
                    to: stationLocation
                )
                let dueSoon = etaSeconds <= dueWindow

                if dueSoon, distance > farFromStationMeters {
                    // The train-side equivalent of the bus #65 case:
                    // CTA says due imminently, GPS says the train is
                    // far from the platform. Hide it.
                    reasons.append(.dueButVehicleNotNearStation)
                    abstain = true
                    score -= 0.40
                } else if dueSoon, distance <= nearStationMeters {
                    reasons.append(.vehicleNearStationAtDue)
                    score += 0.15
                }
            } else if stationLocation == nil {
                reasons.append(.stationLocationUnknown)
            }
        } else {
            // No matching run in the positions feed at all. Strong
            // negative when CTA claims the train is imminent — that's
            // exactly the ghost case. Less severe when the train is
            // far out because CTA can publish a prediction before the
            // run starts reporting positions.
            reasons.append(.vehicleNotFound)

            // CTA insists the train is right at the platform but the
            // positions feed lost it. Pile on — this is the cleanest
            // train-specific ghost signature.
            if arrival.isApproaching {
                reasons.append(.approachingButNoVehicle)
                score -= 0.15
            }

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
        let state: TrainArrivalReliability.State = {
            if abstain { return .doNotDisplay }
            if clamped >= 0.78 { return .highConfidence }
            if clamped >= 0.60 { return .mediumConfidence }
            if clamped >= 0.40 { return .lowConfidence }
            return .unreliable
        }()

        return TrainArrivalReliability(
            id: arrival.id,
            state: state,
            score: clamped,
            reasonCodes: reasons
        )
    }

    private func matchingVehicle(
        for arrival: Arrival,
        in positions: [VehiclePosition]
    ) -> VehiclePosition? {
        let run = arrival.runNumber.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !run.isEmpty else { return nil }
        return positions.first { position in
            guard position.mode == .train else { return false }
            return position.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == run
        }
    }
}
