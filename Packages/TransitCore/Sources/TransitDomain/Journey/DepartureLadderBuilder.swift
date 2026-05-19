import Foundation
import TransitCache
import TransitModels

public struct LadderTransferLeg: Sendable {
    public let transferWalkSeconds: TimeInterval
    public let transferWalkSigmaSeconds: TimeInterval
    public let nextRouteIdentifier: String
    public let nextDirection: String?
    public let nextBoardingPoint: JourneyPoint
    public let nextAlightingPoint: JourneyPoint
    public let nextInVehicleSeconds: TimeInterval
    public let nextInVehicleSigmaSeconds: TimeInterval
    public let nextScheduleHeadwaySeconds: TimeInterval?
    public let nextLiveDepartures: [LiveDeparture]
    public let nextFeedState: FeedState
    public let nextMode: LegMode

    public init(
        transferWalkSeconds: TimeInterval,
        transferWalkSigmaSeconds: TimeInterval,
        nextMode: LegMode,
        nextRouteIdentifier: String,
        nextDirection: String? = nil,
        nextBoardingPoint: JourneyPoint,
        nextAlightingPoint: JourneyPoint,
        nextInVehicleSeconds: TimeInterval,
        nextInVehicleSigmaSeconds: TimeInterval,
        nextScheduleHeadwaySeconds: TimeInterval? = nil,
        nextLiveDepartures: [LiveDeparture],
        nextFeedState: FeedState = .fresh
    ) {
        self.transferWalkSeconds = max(0, transferWalkSeconds)
        self.transferWalkSigmaSeconds = max(0, transferWalkSigmaSeconds)
        self.nextMode = nextMode
        self.nextRouteIdentifier = nextRouteIdentifier
        self.nextDirection = nextDirection
        self.nextBoardingPoint = nextBoardingPoint
        self.nextAlightingPoint = nextAlightingPoint
        self.nextInVehicleSeconds = max(0, nextInVehicleSeconds)
        self.nextInVehicleSigmaSeconds = max(0, nextInVehicleSigmaSeconds)
        self.nextScheduleHeadwaySeconds = nextScheduleHeadwaySeconds
        self.nextLiveDepartures = nextLiveDepartures.sorted { $0.arrivalAt < $1.arrivalAt }
        self.nextFeedState = nextFeedState
    }
}

public struct LadderCandidateSpec: Sendable {
    public let title: String
    public let mode: LegMode
    public let routeIdentifier: String
    public let direction: String?
    public let boardingPoint: JourneyPoint
    public let alightingPoint: JourneyPoint
    public let inVehicleSeconds: TimeInterval
    public let inVehicleSigmaSeconds: TimeInterval
    /// Mean seconds for the origin-to-boarding leg, already paced for the
    /// chosen `boardingMode`. The viewmodel passes this in via the walking
    /// time fetcher; the builder still applies a walk-speed ratio on top
    /// when the mode is `.walk` (see `build`).
    public let boardingMode: LegMode
    public let finalMileSeconds: TimeInterval
    public let finalMileSigmaSeconds: TimeInterval
    public let finalMileMode: LegMode
    public let scheduleHeadwaySeconds: TimeInterval?
    public let liveDepartures: [LiveDeparture]
    public let feedState: FeedState
    public let transfer: LadderTransferLeg?

    public init(
        title: String,
        mode: LegMode,
        routeIdentifier: String,
        direction: String? = nil,
        boardingPoint: JourneyPoint,
        alightingPoint: JourneyPoint,
        inVehicleSeconds: TimeInterval,
        inVehicleSigmaSeconds: TimeInterval,
        boardingMode: LegMode = .walk,
        finalMileSeconds: TimeInterval,
        finalMileSigmaSeconds: TimeInterval,
        finalMileMode: LegMode = .walk,
        scheduleHeadwaySeconds: TimeInterval? = nil,
        liveDepartures: [LiveDeparture],
        feedState: FeedState = .fresh,
        transfer: LadderTransferLeg? = nil
    ) {
        self.title = title
        self.mode = mode
        self.routeIdentifier = routeIdentifier
        self.direction = direction
        self.boardingPoint = boardingPoint
        self.alightingPoint = alightingPoint
        self.inVehicleSeconds = max(0, inVehicleSeconds)
        self.inVehicleSigmaSeconds = max(0, inVehicleSigmaSeconds)
        self.boardingMode = boardingMode
        self.finalMileSeconds = max(0, finalMileSeconds)
        self.finalMileSigmaSeconds = max(0, finalMileSigmaSeconds)
        self.finalMileMode = finalMileMode
        self.scheduleHeadwaySeconds = scheduleHeadwaySeconds
        self.liveDepartures = liveDepartures.sorted { $0.arrivalAt < $1.arrivalAt }
        self.feedState = feedState
        self.transfer = transfer
    }
}

public struct DepartureLadderBuilder: Sendable {
    public let horizonSeconds: TimeInterval
    public let walkSlackSeconds: TimeInterval
    public let dedupeWindowSeconds: TimeInterval
    public let cliffThresholdSeconds: TimeInterval
    public let maxRows: Int
    public let samplesPerRow: Int
    public let rngSeed: UInt64

    public init(
        horizonSeconds: TimeInterval = 90 * 60,
        walkSlackSeconds: TimeInterval = 60,
        dedupeWindowSeconds: TimeInterval = 90,
        cliffThresholdSeconds: TimeInterval = 8 * 60,
        maxRows: Int = 5,
        samplesPerRow: Int = 128,
        rngSeed: UInt64 = 0xC0FFEE_BABA
    ) {
        self.horizonSeconds = max(0, horizonSeconds)
        self.walkSlackSeconds = max(0, walkSlackSeconds)
        self.dedupeWindowSeconds = max(0, dedupeWindowSeconds)
        self.cliffThresholdSeconds = max(0, cliffThresholdSeconds)
        self.maxRows = max(1, maxRows)
        self.samplesPerRow = max(8, samplesPerRow)
        self.rngSeed = rngSeed
    }

    public func build(
        destinationTitle: String,
        origin: JourneyPoint,
        destinationPoint: JourneyPoint,
        snapshot: TransitSnapshot,
        candidates: [LadderCandidateSpec],
        walkSpeedEstimate: WalkSpeedEstimate,
        walkingTimeFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval,
        clock: Clock = SystemClock()
    ) -> DepartureLadder {
        _ = snapshot
        let now = clock.now
        let horizonEnd = now.addingTimeInterval(horizonSeconds)
        let walkRatio = walkSpeedEstimate.confidentRatio(minSamples: 5) ?? 1.0
        let walkConfidence = walkSpeedEstimate.count >= 5 ? min(1.0, 0.5 + Double(walkSpeedEstimate.count) / 60.0) : 0.5
        let composer = JourneyComposer()
        let analyzer = LineHealthAnalyzer()
        var rng = SeededLCG(seed: rngSeed)

        var rowsAccumulator: [DepartureLadderRow] = []
        var lineHealth: [LineHealthSnapshot] = []

        for spec in candidates {
            let stopProcess = StopArrivalProcess(
                route: spec.routeIdentifier,
                direction: spec.direction,
                generatedAt: now,
                departures: spec.liveDepartures,
                scheduleHeadwaySeconds: spec.scheduleHeadwaySeconds,
                feedState: spec.feedState
            )
            lineHealth.append(
                analyzer.analyze(
                    route: spec.routeIdentifier,
                    direction: spec.direction,
                    upcomingArrivals: spec.liveDepartures.map { $0.arrivalAt },
                    baselineHeadwaySeconds: spec.scheduleHeadwaySeconds,
                    feedState: spec.feedState,
                    generatedAt: now
                )
            )

            let transferStopProcess: StopArrivalProcess? = spec.transfer.map { transfer in
                StopArrivalProcess(
                    route: transfer.nextRouteIdentifier,
                    direction: transfer.nextDirection,
                    generatedAt: now,
                    departures: transfer.nextLiveDepartures,
                    scheduleHeadwaySeconds: transfer.nextScheduleHeadwaySeconds,
                    feedState: transfer.nextFeedState
                )
            }
            if let transferStopProcess, let transfer = spec.transfer {
                lineHealth.append(
                    analyzer.analyze(
                        route: transfer.nextRouteIdentifier,
                        direction: transfer.nextDirection,
                        upcomingArrivals: transfer.nextLiveDepartures.map { $0.arrivalAt },
                        baselineHeadwaySeconds: transfer.nextScheduleHeadwaySeconds,
                        feedState: transfer.nextFeedState,
                        generatedAt: now
                    )
                )
                _ = transferStopProcess
            }

            let baseBoardingSeconds = walkingTimeFetcher(origin, spec.boardingPoint)
            // Walk-equivalent ratio only applies to legs the user actually walks.
            // Biking comes in already paced from the viewmodel; applying the
            // walking-confidence ratio to it would double-discount.
            let boardingWalkAdjusted = spec.boardingMode == .walk
            let boardingMean = boardingWalkAdjusted
                ? baseBoardingSeconds * walkRatio
                : baseBoardingSeconds
            let boardingSigma = max(30, boardingMean * 0.12)
            let boardingConservative = boardingMean + 0.8416 * boardingSigma

            let finalMileWalkAdjusted = spec.finalMileMode == .walk
            let finalMileMean = finalMileWalkAdjusted
                ? spec.finalMileSeconds * walkRatio
                : spec.finalMileSeconds
            let finalMileSigma = max(30, finalMileMean * 0.12) + spec.finalMileSigmaSeconds

            let (option, kernels) = buildOption(
                spec: spec,
                stopProcess: stopProcess,
                transferStopProcess: transferStopProcess,
                origin: origin,
                destinationPoint: destinationPoint,
                boardingMean: boardingMean,
                boardingSigma: boardingSigma,
                walkConfidence: walkConfidence,
                walkSpeedSamples: walkSpeedEstimate.count,
                finalMileMean: finalMileMean,
                finalMileSigma: finalMileSigma,
                walkRatio: walkRatio
            )

            for departure in spec.liveDepartures where departure.arrivalAt <= horizonEnd {
                let leaveBy = departure.arrivalAt.addingTimeInterval(-(boardingConservative + walkSlackSeconds))
                if leaveBy < now.addingTimeInterval(-60) { continue }

                let userAtStop = leaveBy.addingTimeInterval(boardingMean)
                let waitForecast = stopProcess.waitDistribution(arrivingAt: userAtStop)
                let downstreamRisk = downgradeIfFeedShaky(waitForecast.state, feedState: spec.feedState)

                let distribution = composer.compose(
                    option: option,
                    legProcesses: kernels,
                    startingAt: leaveBy,
                    samples: samplesPerRow,
                    rng: &rng
                )
                let totalDuration = distribution.totalDuration

                let arriveLow = leaveBy.addingTimeInterval(totalDuration.p50)
                let arriveHigh = leaveBy.addingTimeInterval(totalDuration.p80)

                let catchProbability = max(0, min(1, 1 - distribution.failureProbability))
                let combinedRisk = combineRisk(downstreamRisk, failureProbability: distribution.failureProbability)
                let secondary = secondaryLabel(risk: combinedRisk, spec: spec)

                let legs = buildLegs(
                    spec: spec,
                    leaveBy: leaveBy,
                    boardingSeconds: boardingMean,
                    departureAt: departure.arrivalAt,
                    finalMileSeconds: finalMileMean
                )

                rowsAccumulator.append(
                    DepartureLadderRow(
                        leaveByAt: leaveBy,
                        boardingAt: departure.arrivalAt,
                        totalDuration: totalDuration,
                        arrivalAt: DepartureLadderRow.ArrivalWindow(low: arriveLow, high: arriveHigh),
                        primaryLabel: option.title,
                        secondaryLabel: secondary,
                        risk: combinedRisk,
                        note: waitForecast.explanation,
                        catchProbability: catchProbability,
                        missCostSeconds: nil,
                        legs: legs
                    )
                )
            }
        }

        let collapsed = collapse(rows: rowsAccumulator)
        let trimmed = Array(collapsed.prefix(maxRows))
        let withMissCost = annotateMissCost(rows: trimmed)
        let (cliffAt, gapSeconds) = detectCliff(rows: withMissCost)
        let headline = cliffAt.map { cliffLeaveBy in
            let waitMinutes = Int((cliffLeaveBy.timeIntervalSince(now) / 60).rounded())
            let jumpMinutes = Int(((gapSeconds ?? 0) / 60).rounded())
            if waitMinutes <= 0 {
                return "Leave now or arrival jumps ~\(jumpMinutes) min."
            }
            return "You can wait \(waitMinutes) min. After that arrival jumps ~\(jumpMinutes) min."
        }

        return DepartureLadder(
            destinationTitle: destinationTitle,
            generatedAt: now,
            rows: withMissCost,
            headline: headline,
            nextCliffAt: cliffAt,
            lineHealth: lineHealth
        )
    }

    private func buildOption(
        spec: LadderCandidateSpec,
        stopProcess: StopArrivalProcess,
        transferStopProcess: StopArrivalProcess?,
        origin: JourneyPoint,
        destinationPoint: JourneyPoint,
        boardingMean: TimeInterval,
        boardingSigma: TimeInterval,
        walkConfidence: Double,
        walkSpeedSamples: Int,
        finalMileMean: TimeInterval,
        finalMileSigma: TimeInterval,
        walkRatio: Double
    ) -> (JourneyOption, [UUID: any PreparedLegProcess]) {
        let boardingLeg = LegCandidate(
            mode: spec.boardingMode,
            displayLabel: boardingDisplayLabel(spec.boardingMode),
            fromPoint: origin,
            toPoint: spec.boardingPoint
        )
        // The composer kernel still operates as a Gaussian draw whether the
        // user walks or bikes; the only difference is the mean we feed it.
        let boardingPrepared: any PreparedLegProcess = PreparedWalkProcess(
            expectedSeconds: boardingMean,
            appliedRatio: 1.0,
            jitterCoefficient: boardingSigma / max(1, boardingMean),
            confidence: walkConfidence,
            sampleCount: walkSpeedSamples
        )

        let transit = LegCandidate(
            mode: spec.mode,
            displayLabel: spec.title,
            fromPoint: spec.boardingPoint,
            toPoint: spec.alightingPoint
        )
        let transitPrepared: any PreparedLegProcess = PreparedTransitLeg(
            mode: spec.mode,
            stopArrivalProcess: stopProcess,
            inVehicleMean: spec.inVehicleSeconds,
            inVehicleSigma: spec.inVehicleSigmaSeconds
        )

        var slots: [JourneySlot] = [.fixed(boardingLeg), .fixed(transit)]
        var kernels: [UUID: any PreparedLegProcess] = [
            boardingLeg.id: boardingPrepared,
            transit.id: transitPrepared
        ]

        var title = spec.title

        if let transfer = spec.transfer, let transferStopProcess = transferStopProcess {
            let transferWalk = LegCandidate(
                mode: .walk,
                displayLabel: "Transfer walk",
                fromPoint: spec.alightingPoint,
                toPoint: transfer.nextBoardingPoint
            )
            let transferWalkPrepared: any PreparedLegProcess = PreparedWalkProcess(
                expectedSeconds: transfer.transferWalkSeconds * walkRatio,
                appliedRatio: 1.0,
                jitterCoefficient: (transfer.transferWalkSigmaSeconds + 30) / max(1, transfer.transferWalkSeconds * walkRatio),
                confidence: walkConfidence,
                sampleCount: walkSpeedSamples
            )

            let secondTransit = LegCandidate(
                mode: transfer.nextMode,
                displayLabel: "\(transfer.nextRouteIdentifier) ride",
                fromPoint: transfer.nextBoardingPoint,
                toPoint: transfer.nextAlightingPoint
            )
            let secondTransitPrepared: any PreparedLegProcess = PreparedTransitLeg(
                mode: transfer.nextMode,
                stopArrivalProcess: transferStopProcess,
                inVehicleMean: transfer.nextInVehicleSeconds,
                inVehicleSigma: transfer.nextInVehicleSigmaSeconds
            )

            slots.append(.fixed(transferWalk))
            slots.append(.fixed(secondTransit))
            kernels[transferWalk.id] = transferWalkPrepared
            kernels[secondTransit.id] = secondTransitPrepared

            title = "\(spec.title) → \(transfer.nextRouteIdentifier)"
        }

        let finalLeg = LegCandidate(
            mode: spec.finalMileMode,
            displayLabel: finalMileDisplayLabel(spec.finalMileMode),
            fromPoint: spec.transfer?.nextAlightingPoint ?? spec.alightingPoint,
            toPoint: destinationPoint
        )
        let finalPrepared: any PreparedLegProcess = PreparedWalkProcess(
            expectedSeconds: finalMileMean,
            appliedRatio: 1.0,
            jitterCoefficient: finalMileSigma / max(1, finalMileMean),
            confidence: walkConfidence,
            sampleCount: walkSpeedSamples
        )
        slots.append(.fixed(finalLeg))
        kernels[finalLeg.id] = finalPrepared

        let option = JourneyOption(title: title, summary: spec.title, slots: slots)
        return (option, kernels)
    }

    private func boardingDisplayLabel(_ mode: LegMode) -> String {
        isBikeMode(mode) ? "Bike to boarding" : "Walk to boarding"
    }

    private func finalMileDisplayLabel(_ mode: LegMode) -> String {
        isBikeMode(mode) ? "Bike to destination" : "Walk to destination"
    }

    private func isBikeMode(_ mode: LegMode) -> Bool {
        switch mode {
        case .divvyClassic, .divvyEBike, .freeBikeParking: true
        default: false
        }
    }

    private func buildLegs(
        spec: LadderCandidateSpec,
        leaveBy: Date,
        boardingSeconds: TimeInterval,
        departureAt: Date,
        finalMileSeconds: TimeInterval
    ) -> [DepartureLadderLeg] {
        var legs: [DepartureLadderLeg] = []

        let boardingArrival = leaveBy.addingTimeInterval(boardingSeconds)
        let boardingVerb = isBikeMode(spec.boardingMode) ? "Bike" : "Walk"
        legs.append(
            DepartureLadderLeg(
                mode: spec.boardingMode,
                label: "\(boardingVerb) to \(spec.boardingPoint.displayTitle)",
                meanSeconds: boardingSeconds,
                arrivalMean: boardingArrival
            )
        )

        let firstAlighting = spec.transfer?.nextBoardingPoint != nil ? spec.alightingPoint : spec.alightingPoint
        let firstRideArrival = departureAt.addingTimeInterval(spec.inVehicleSeconds)
        legs.append(
            DepartureLadderLeg(
                mode: spec.mode,
                label: "\(transitLabel(mode: spec.mode, route: spec.routeIdentifier)) to \(firstAlighting.displayTitle)",
                meanSeconds: spec.inVehicleSeconds,
                arrivalMean: firstRideArrival
            )
        )

        var lastClock = firstRideArrival
        if let transfer = spec.transfer {
            let transferArrival = lastClock.addingTimeInterval(transfer.transferWalkSeconds)
            legs.append(
                DepartureLadderLeg(
                    mode: .walk,
                    label: "Transfer walk to \(transfer.nextBoardingPoint.displayTitle)",
                    meanSeconds: transfer.transferWalkSeconds,
                    arrivalMean: transferArrival
                )
            )
            let secondRideArrival = transferArrival.addingTimeInterval(transfer.nextInVehicleSeconds)
            legs.append(
                DepartureLadderLeg(
                    mode: transfer.nextMode,
                    label: "\(transitLabel(mode: transfer.nextMode, route: transfer.nextRouteIdentifier)) to \(transfer.nextAlightingPoint.displayTitle)",
                    meanSeconds: transfer.nextInVehicleSeconds,
                    arrivalMean: secondRideArrival
                )
            )
            lastClock = secondRideArrival
        }

        let finalArrival = lastClock.addingTimeInterval(finalMileSeconds)
        legs.append(
            DepartureLadderLeg(
                mode: spec.finalMileMode,
                label: finalMileDisplayLabel(spec.finalMileMode),
                meanSeconds: finalMileSeconds,
                arrivalMean: finalArrival
            )
        )
        return legs
    }

    private func transitLabel(mode: LegMode, route: String) -> String {
        switch mode {
        case .ctaTrain: "Ride \(route) Line"
        case .ctaBus: "Bus \(route)"
        case .metra: "Metra \(route)"
        case .intercampus: "Intercampus shuttle"
        case .divvyClassic: "Ride Divvy"
        case .divvyEBike: "Ride Divvy e-bike"
        default: "Ride \(route)"
        }
    }

    private func secondaryLabel(risk: WaitReasonableness, spec: LadderCandidateSpec) -> String? {
        if risk == .badGap { return "gap" }
        if risk == .bunched { return "bunched" }
        if risk == .feedUnreliable { return "feed unreliable" }
        if risk == .riskyWait { return "tight" }
        if spec.transfer != nil { return "transfer" }
        if isBikeMode(spec.mode) { return "bike" }
        return spec.title.lowercased().contains("bus") ? "bus" : nil
    }

    private func combineRisk(_ baseline: WaitReasonableness, failureProbability: Double) -> WaitReasonableness {
        if failureProbability >= 0.25 { return .badGap }
        if failureProbability >= 0.10, baseline == .acceptableWait || baseline == .goodWait { return .riskyWait }
        return baseline
    }

    private func collapse(rows: [DepartureLadderRow]) -> [DepartureLadderRow] {
        let sorted = rows.sorted { $0.leaveByAt < $1.leaveByAt }
        var kept: [DepartureLadderRow] = []
        for row in sorted {
            if let last = kept.last,
               row.leaveByAt.timeIntervalSince(last.leaveByAt) < dedupeWindowSeconds {
                continue
            }
            kept.append(row)
        }
        return kept
    }

    private func annotateMissCost(rows: [DepartureLadderRow]) -> [DepartureLadderRow] {
        guard rows.count >= 2 else { return rows }
        var result: [DepartureLadderRow] = []
        for i in rows.indices {
            let row = rows[i]
            let missCost: TimeInterval?
            if i + 1 < rows.count {
                missCost = rows[i + 1].arrivalAt.low.timeIntervalSince(row.arrivalAt.low)
            } else {
                missCost = nil
            }
            result.append(
                DepartureLadderRow(
                    id: row.id,
                    leaveByAt: row.leaveByAt,
                    boardingAt: row.boardingAt,
                    totalDuration: row.totalDuration,
                    arrivalAt: row.arrivalAt,
                    primaryLabel: row.primaryLabel,
                    secondaryLabel: row.secondaryLabel,
                    risk: row.risk,
                    note: row.note,
                    catchProbability: row.catchProbability,
                    missCostSeconds: missCost,
                    legs: row.legs
                )
            )
        }
        return result
    }

    private func detectCliff(rows: [DepartureLadderRow]) -> (Date?, TimeInterval?) {
        guard rows.count >= 2 else { return (nil, nil) }
        for i in 0..<(rows.count - 1) {
            let gap = rows[i + 1].arrivalAt.low.timeIntervalSince(rows[i].arrivalAt.low)
            if gap > cliffThresholdSeconds {
                return (rows[i].leaveByAt, gap)
            }
        }
        return (nil, nil)
    }

    private func downgradeIfFeedShaky(_ state: WaitReasonableness, feedState: FeedState) -> WaitReasonableness {
        if feedState == .missing { return .unknown }
        if feedState == .stale { return .feedUnreliable }
        return state
    }
}
