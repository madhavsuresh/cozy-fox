import Foundation
import TransitCache
import TransitModels

public struct LadderCandidateSpec: Sendable {
    public let title: String
    public let mode: LegMode
    public let routeIdentifier: String
    public let direction: String?
    public let boardingPoint: JourneyPoint
    public let alightingPoint: JourneyPoint
    public let inVehicleSeconds: TimeInterval
    public let inVehicleSigmaSeconds: TimeInterval
    public let finalMileSeconds: TimeInterval
    public let finalMileSigmaSeconds: TimeInterval
    public let scheduleHeadwaySeconds: TimeInterval?
    public let liveDepartures: [LiveDeparture]
    public let feedState: FeedState

    public init(
        title: String,
        mode: LegMode,
        routeIdentifier: String,
        direction: String? = nil,
        boardingPoint: JourneyPoint,
        alightingPoint: JourneyPoint,
        inVehicleSeconds: TimeInterval,
        inVehicleSigmaSeconds: TimeInterval,
        finalMileSeconds: TimeInterval,
        finalMileSigmaSeconds: TimeInterval,
        scheduleHeadwaySeconds: TimeInterval? = nil,
        liveDepartures: [LiveDeparture],
        feedState: FeedState = .fresh
    ) {
        self.title = title
        self.mode = mode
        self.routeIdentifier = routeIdentifier
        self.direction = direction
        self.boardingPoint = boardingPoint
        self.alightingPoint = alightingPoint
        self.inVehicleSeconds = max(0, inVehicleSeconds)
        self.inVehicleSigmaSeconds = max(0, inVehicleSigmaSeconds)
        self.finalMileSeconds = max(0, finalMileSeconds)
        self.finalMileSigmaSeconds = max(0, finalMileSigmaSeconds)
        self.scheduleHeadwaySeconds = scheduleHeadwaySeconds
        self.liveDepartures = liveDepartures.sorted { $0.arrivalAt < $1.arrivalAt }
        self.feedState = feedState
    }
}

public struct DepartureLadderBuilder: Sendable {
    public let horizonSeconds: TimeInterval
    public let walkSlackSeconds: TimeInterval
    public let dedupeWindowSeconds: TimeInterval
    public let cliffThresholdSeconds: TimeInterval
    public let maxRows: Int

    public init(
        horizonSeconds: TimeInterval = 90 * 60,
        walkSlackSeconds: TimeInterval = 60,
        dedupeWindowSeconds: TimeInterval = 90,
        cliffThresholdSeconds: TimeInterval = 8 * 60,
        maxRows: Int = 5
    ) {
        self.horizonSeconds = max(0, horizonSeconds)
        self.walkSlackSeconds = max(0, walkSlackSeconds)
        self.dedupeWindowSeconds = max(0, dedupeWindowSeconds)
        self.cliffThresholdSeconds = max(0, cliffThresholdSeconds)
        self.maxRows = max(1, maxRows)
    }

    public func build(
        destinationTitle: String,
        origin: JourneyPoint,
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

        var rowsAccumulator: [DepartureLadderRow] = []
        var lineHealth: [LineHealthSnapshot] = []
        let analyzer = LineHealthAnalyzer()

        for spec in candidates {
            let stopProcess = StopArrivalProcess(
                route: spec.routeIdentifier,
                direction: spec.direction,
                generatedAt: now,
                departures: spec.liveDepartures,
                scheduleHeadwaySeconds: spec.scheduleHeadwaySeconds,
                feedState: spec.feedState
            )
            let health = analyzer.analyze(
                route: spec.routeIdentifier,
                direction: spec.direction,
                upcomingArrivals: spec.liveDepartures.map { $0.arrivalAt },
                baselineHeadwaySeconds: spec.scheduleHeadwaySeconds,
                feedState: spec.feedState,
                generatedAt: now
            )
            lineHealth.append(health)

            let baseWalkSeconds = walkingTimeFetcher(origin, spec.boardingPoint)
            let walkMean = baseWalkSeconds * walkRatio
            let walkSigma = max(30, walkMean * 0.12)
            let walkConservative = walkMean + 0.8416 * walkSigma

            for departure in spec.liveDepartures where departure.arrivalAt <= horizonEnd {
                let leaveBy = departure.arrivalAt.addingTimeInterval(-(walkConservative + walkSlackSeconds))
                if leaveBy < now.addingTimeInterval(-60) { continue }

                let userAtStop = leaveBy.addingTimeInterval(walkMean)
                let waitForecast = stopProcess.waitDistribution(arrivingAt: userAtStop)
                let inVehicleMean = spec.inVehicleSeconds
                let inVehicleSigma = spec.inVehicleSigmaSeconds
                let finalMileMean = spec.finalMileSeconds * walkRatio
                let finalMileSigma = max(30, finalMileMean * 0.12) + spec.finalMileSigmaSeconds

                let arriveDoorP50 = departure.arrivalAt.addingTimeInterval(inVehicleMean + finalMileMean)
                let arriveDoorP80 = departure.arrivalAt.addingTimeInterval(
                    inVehicleMean + 0.8416 * inVehicleSigma + finalMileMean + 0.8416 * finalMileSigma
                )

                let totalP50 = arriveDoorP50.timeIntervalSince(leaveBy)
                let totalP80 = arriveDoorP80.timeIntervalSince(leaveBy)
                let totalMean = (totalP50 + totalP80) / 2
                let totalDistribution = TimeDistributionSummary(
                    mean: max(0, totalMean),
                    p50: max(0, totalP50),
                    p80: max(0, totalP80),
                    p90: max(0, totalP80 + 1.0 * (totalP80 - totalP50)),
                    confidence: min(walkConfidence, 0.85),
                    sampleCount: max(spec.liveDepartures.count, 1)
                )

                let catchProbability: Double = departure.isApproaching ? 0.95 : 0.85
                let risk = downgradeIfFeedShaky(waitForecast.state, feedState: spec.feedState)

                let secondary: String? = {
                    if risk == .badGap { return "gap" }
                    if risk == .bunched { return "bunched" }
                    if risk == .feedUnreliable { return "feed unreliable" }
                    if risk == .riskyWait { return "tight" }
                    return spec.title.lowercased().contains("bus") ? "bus" : nil
                }()

                rowsAccumulator.append(
                    DepartureLadderRow(
                        leaveByAt: leaveBy,
                        totalDuration: totalDistribution,
                        arrivalAt: DepartureLadderRow.ArrivalWindow(low: arriveDoorP50, high: arriveDoorP80),
                        primaryLabel: spec.title,
                        secondaryLabel: secondary,
                        risk: risk,
                        note: waitForecast.explanation,
                        catchProbability: catchProbability,
                        missCostSeconds: nil
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
                    totalDuration: row.totalDuration,
                    arrivalAt: row.arrivalAt,
                    primaryLabel: row.primaryLabel,
                    secondaryLabel: row.secondaryLabel,
                    risk: row.risk,
                    note: row.note,
                    catchProbability: row.catchProbability,
                    missCostSeconds: missCost
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
