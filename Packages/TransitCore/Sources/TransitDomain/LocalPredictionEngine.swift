import Foundation
import TransitModels

/// Snapshot of the local commute predictor's current best guess. Renders in
/// the Settings "Local predictions" panel and feeds the autopinner.
public struct LocalMobilityPrediction: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case disabled
        case manualOverride
        case missingLocation
        case missingAnchor
        case notInCommuteWindow
        case suppressedByMotion
        case heldDuringTransit
        case noRoute
        case predicted
    }

    public enum DepartureMatch: String, Sendable, Hashable {
        case insideLearnedWindow
        case nearLearnedWindow
        case outsideLearnedWindow
        case fallbackWindow
        case noLearnedWindow
    }

    public struct RouteCandidate: Sendable, Hashable, Identifiable {
        public let id: String
        public let mode: MobilityProfileSummary.RoutePattern.Mode
        public let routeId: String
        public let direction: CommuteDirection
        public let stationLabel: String?
        public let directionLabel: String?
        public let totalCount: Int
        public let recentObservationCount: Int
        public let score: Double
        public let source: Source

        public enum Source: String, Sendable, Hashable {
            /// Came from the live `routeObservations` array (still in the
            /// 14-day window).
            case raw
            /// Came from the long-lived summary aggregate.
            case summary
        }

        public init(
            mode: MobilityProfileSummary.RoutePattern.Mode,
            routeId: String,
            direction: CommuteDirection,
            stationLabel: String?,
            directionLabel: String?,
            totalCount: Int,
            recentObservationCount: Int,
            score: Double,
            source: Source
        ) {
            self.id = "\(direction.rawValue):\(mode.rawValue):\(routeId)"
            self.mode = mode
            self.routeId = routeId
            self.direction = direction
            self.stationLabel = stationLabel
            self.directionLabel = directionLabel
            self.totalCount = totalCount
            self.recentObservationCount = recentObservationCount
            self.score = score
            self.source = source
        }
    }

    public let reason: Reason
    public let direction: CommuteDirection?
    public let confidence: Double
    /// 0–1 estimate of *how much* the predictor knows. Independent of the
    /// per-decision `confidence` — high coverage with a stale signal can still
    /// produce low confidence on a given call.
    public let coverage: Double
    public let departureMatch: DepartureMatch
    public let peakDepartureWeekday: Int?
    public let peakDepartureHour: Int?
    public let learnedDepartureSampleCount: Int
    public let routeCandidates: [RouteCandidate]
    public let topCandidate: RouteCandidate?
    public let reasonText: String

    public init(
        reason: Reason,
        direction: CommuteDirection?,
        confidence: Double,
        coverage: Double,
        departureMatch: DepartureMatch,
        peakDepartureWeekday: Int?,
        peakDepartureHour: Int?,
        learnedDepartureSampleCount: Int,
        routeCandidates: [RouteCandidate],
        reasonText: String
    ) {
        self.reason = reason
        self.direction = direction
        self.confidence = confidence
        self.coverage = coverage
        self.departureMatch = departureMatch
        self.peakDepartureWeekday = peakDepartureWeekday
        self.peakDepartureHour = peakDepartureHour
        self.learnedDepartureSampleCount = learnedDepartureSampleCount
        self.routeCandidates = routeCandidates
        self.topCandidate = routeCandidates.first
        self.reasonText = reasonText
    }
}

/// On-device prediction layer that combines current motion + context with the
/// derived `MobilityProfileSummary` to produce a single, stable
/// `LocalMobilityPrediction`. Used by the Settings panel and as a fallback for
/// the autopinner once raw history has aged out.
public struct LocalPredictionEngine: Sendable {
    public let clock: Clock
    public let manualOverrideSeconds: TimeInterval

    public init(
        clock: Clock = SystemClock(),
        manualOverrideSeconds: TimeInterval = 30 * 60
    ) {
        self.clock = clock
        self.manualOverrideSeconds = manualOverrideSeconds
    }

    public func predict(
        preferences: UserRoutePreferences,
        anchors: CommuteAnchors,
        profile: MobilityProfile,
        location: LastKnownLocation?,
        context: CommuteContext,
        motion: MotionContext? = nil
    ) -> LocalMobilityPrediction {
        if !preferences.autopinEnabled {
            return base(reason: .disabled, reasonText: "Auto-pin is off.")
        }
        if hasActiveManualOverride(preferences) {
            return base(
                reason: .manualOverride,
                reasonText: "Paused by a recent manual pin."
            )
        }
        if let motion,
           motion == .automotive || motion == .cycling,
           preferences.pinSource == .automatic,
           preferences.hasPinnedTransit
        {
            return base(
                reason: .heldDuringTransit,
                direction: preferences.autoPinnedDirection,
                reasonText: "Holding the current pin while the motion coprocessor reports you're mid-trip."
            )
        }

        guard location != nil else {
            return base(reason: .missingLocation, reasonText: "Waiting for a current location.")
        }

        let direction = predictedDirection(context: context, profile: profile, motion: motion)
        guard let direction else {
            if context == .atHome, motion == .stationary {
                return base(
                    reason: .suppressedByMotion,
                    reasonText: "At home and still — motion coprocessor reports no movement."
                )
            }
            return base(
                reason: .notInCommuteWindow,
                reasonText: contextOutsideWindowText(context: context)
            )
        }

        if targetAnchor(for: direction, anchors: anchors) == nil {
            return base(
                reason: .missingAnchor,
                direction: direction,
                reasonText: "Missing the \(direction == .toWork ? "work" : "home") anchor."
            )
        }

        let departure = analyzeDepartureMatch(direction: direction, profile: profile, context: context)
        let candidates = topRouteCandidates(direction: direction, profile: profile)
        let coverage = coverageScore(profile: profile)
        let confidence = confidenceScore(
            direction: direction,
            profile: profile,
            motion: motion,
            departure: departure,
            candidates: candidates
        )

        let reasonText = buildReasonText(
            direction: direction,
            context: context,
            motion: motion,
            departure: departure,
            candidate: candidates.first
        )

        return LocalMobilityPrediction(
            reason: candidates.isEmpty ? .noRoute : .predicted,
            direction: direction,
            confidence: confidence,
            coverage: coverage,
            departureMatch: departure.match,
            peakDepartureWeekday: departure.peakWeekday,
            peakDepartureHour: departure.peakHour,
            learnedDepartureSampleCount: departure.sampleCount,
            routeCandidates: candidates,
            reasonText: reasonText
        )
    }

    private func base(
        reason: LocalMobilityPrediction.Reason,
        direction: CommuteDirection? = nil,
        reasonText: String
    ) -> LocalMobilityPrediction {
        LocalMobilityPrediction(
            reason: reason,
            direction: direction,
            confidence: 0,
            coverage: 0,
            departureMatch: .noLearnedWindow,
            peakDepartureWeekday: nil,
            peakDepartureHour: nil,
            learnedDepartureSampleCount: 0,
            routeCandidates: [],
            reasonText: reasonText
        )
    }

    private func contextOutsideWindowText(context: CommuteContext) -> String {
        switch context {
        case .atHome:
            return "At home outside the learned work-commute window."
        case .unknown:
            return "Waiting for a place classification."
        case .atWork, .elsewhere:
            return "Not in a commute window right now."
        }
    }

    private func hasActiveManualOverride(_ preferences: UserRoutePreferences) -> Bool {
        guard let last = preferences.lastManualPinAt else { return false }
        guard clock.now.timeIntervalSince(last) < manualOverrideSeconds else { return false }
        return clock.calendar.isDate(last, inSameDayAs: clock.now)
    }

    private func targetAnchor(
        for direction: CommuteDirection,
        anchors: CommuteAnchors
    ) -> CommuteAnchors.Anchor? {
        switch direction {
        case .toHome: return anchors.home
        case .toWork: return anchors.work
        case .anytime: return nil
        }
    }

    private func predictedDirection(
        context: CommuteContext,
        profile: MobilityProfile,
        motion: MotionContext?
    ) -> CommuteDirection? {
        switch context {
        case .atHome:
            if motion == .stationary { return nil }
            return shouldSurfaceToWorkFromHome(profile: profile, motion: motion) ? .toWork : nil
        case .atWork, .elsewhere:
            return .toHome
        case .unknown:
            return nil
        }
    }

    private func shouldSurfaceToWorkFromHome(
        profile: MobilityProfile,
        motion: MotionContext?
    ) -> Bool {
        guard isWeekday(clock.now) else { return false }
        if motion == .walking || motion == .running { return true }
        let hour = clock.calendar.component(.hour, from: clock.now)
        let weekday = clock.calendar.component(.weekday, from: clock.now)

        let rawDepartures = profile.observations.filter {
            $0.source == .exitedHome
                && $0.direction == .toWork
                && isWeekday(weekday: $0.weekday)
        }

        let summaryWindow = profile.summary.departureWindow(source: .exitedHome, direction: .toWork)
        let summarySamples = summaryWindow?.totalCount ?? 0
        let total = max(rawDepartures.count, summarySamples)
        guard total >= 3 else {
            return (5...11).contains(hour)
        }

        if rawDepartures.count >= 3 {
            let sameWeekday = rawDepartures.filter { $0.weekday == weekday }
            let sample = sameWeekday.count >= 2 ? sameWeekday : rawDepartures
            let byHour = Dictionary(grouping: sample, by: \.hour)
            guard let peak = byHour.max(by: { $0.value.count < $1.value.count })?.key else {
                return false
            }
            return hourDistance(hour, peak) <= 2
        }

        if let summaryWindow {
            if summaryWindow.matchesWindow(weekday: weekday, hour: hour, hourWindow: 2, minSamples: 2) {
                return true
            }
            if let peakHour = summaryWindow.peakHour {
                return hourDistance(hour, peakHour) <= 2
            }
        }
        return (5...11).contains(hour)
    }

    private struct DepartureAnalysis {
        let match: LocalMobilityPrediction.DepartureMatch
        let peakWeekday: Int?
        let peakHour: Int?
        let sampleCount: Int
    }

    private func analyzeDepartureMatch(
        direction: CommuteDirection,
        profile: MobilityProfile,
        context: CommuteContext
    ) -> DepartureAnalysis {
        let source: MobilityProfile.Observation.Source?
        switch direction {
        case .toWork:
            source = .exitedHome
        case .toHome:
            source = .exitedWork
        case .anytime:
            source = nil
        }
        guard let source else {
            return DepartureAnalysis(
                match: .noLearnedWindow,
                peakWeekday: nil,
                peakHour: nil,
                sampleCount: 0
            )
        }

        let now = clock.now
        let weekday = clock.calendar.component(.weekday, from: now)
        let hour = clock.calendar.component(.hour, from: now)

        let rawCount = profile.observations.filter {
            $0.source == source && $0.direction == direction
        }.count
        let window = profile.summary.departureWindow(source: source, direction: direction)
        let totalSamples = max(rawCount, window?.totalCount ?? 0)
        let peak = window?.peakBucket
        let peakHour = peak?.hour ?? window?.peakHour

        let match: LocalMobilityPrediction.DepartureMatch
        if let window, !window.weekdayHourCounts.isEmpty {
            if window.matchesWindow(weekday: weekday, hour: hour, hourWindow: 1, minSamples: 2) {
                match = .insideLearnedWindow
            } else if window.matchesWindow(weekday: weekday, hour: hour, hourWindow: 2, minSamples: 2) {
                match = .nearLearnedWindow
            } else {
                match = .outsideLearnedWindow
            }
        } else if context == .atHome && (5...11).contains(hour) && (2...6).contains(weekday) && direction == .toWork {
            match = .fallbackWindow
        } else if context == .atWork && (14...20).contains(hour) && direction == .toHome {
            match = .fallbackWindow
        } else {
            match = .noLearnedWindow
        }

        return DepartureAnalysis(
            match: match,
            peakWeekday: peak?.weekday,
            peakHour: peakHour,
            sampleCount: totalSamples
        )
    }

    private func topRouteCandidates(
        direction: CommuteDirection,
        profile: MobilityProfile
    ) -> [LocalMobilityPrediction.RouteCandidate] {
        let weekday = clock.calendar.component(.weekday, from: clock.now)
        let hour = clock.calendar.component(.hour, from: clock.now)

        struct PartialScore {
            var rawScore: Double = 0
            var rawCount: Int = 0
            var summaryScore: Double = 0
            var summaryCount: Int = 0
            var stationLabel: String?
            var directionLabel: String?
            var mode: MobilityProfileSummary.RoutePattern.Mode
            var routeId: String
        }

        var partials: [String: PartialScore] = [:]

        for observation in profile.routeObservations where observation.direction == direction {
            let score = rawObservationScore(observation: observation, weekday: weekday, hour: hour)
            if let line = observation.line {
                let key = MobilityProfileSummary.RoutePattern.key(
                    direction: direction,
                    mode: .train,
                    routeId: line.rawValue
                )
                var partial = partials[key] ?? PartialScore(mode: .train, routeId: line.rawValue)
                partial.rawScore += score
                partial.rawCount += 1
                if partial.stationLabel == nil {
                    partial.stationLabel = observation.stationId.map(String.init)
                }
                if partial.directionLabel == nil {
                    partial.directionLabel = observation.trainDestination
                }
                partials[key] = partial
            }
            if let route = observation.busRoute {
                let key = MobilityProfileSummary.RoutePattern.key(
                    direction: direction,
                    mode: .bus,
                    routeId: route
                )
                var partial = partials[key] ?? PartialScore(mode: .bus, routeId: route)
                partial.rawScore += score
                partial.rawCount += 1
                if partial.directionLabel == nil {
                    partial.directionLabel = observation.busDirection
                }
                partials[key] = partial
            }
            if let route = observation.metraRoute {
                let key = MobilityProfileSummary.RoutePattern.key(
                    direction: direction,
                    mode: .metra,
                    routeId: route
                )
                var partial = partials[key] ?? PartialScore(mode: .metra, routeId: route)
                partial.rawScore += score
                partial.rawCount += 1
                if partial.stationLabel == nil {
                    partial.stationLabel = observation.metraStationId
                }
                partials[key] = partial
            }
        }

        for pattern in profile.summary.patterns(direction: direction) {
            let summaryScore = summaryPatternScore(pattern: pattern, weekday: weekday, hour: hour)
            var partial = partials[pattern.key] ?? PartialScore(
                mode: pattern.mode,
                routeId: pattern.routeId
            )
            partial.summaryScore = summaryScore
            partial.summaryCount = pattern.totalCount
            if partial.stationLabel == nil, let station = pattern.topStationId {
                partial.stationLabel = station
            }
            if partial.directionLabel == nil, let label = pattern.topDirectionLabel {
                partial.directionLabel = label
            }
            partials[pattern.key] = partial
        }

        let candidates: [LocalMobilityPrediction.RouteCandidate] = partials.values.map { partial in
            let combined = partial.rawScore + partial.summaryScore * 0.6
            let source: LocalMobilityPrediction.RouteCandidate.Source =
                partial.rawCount > 0 ? .raw : .summary
            return LocalMobilityPrediction.RouteCandidate(
                mode: partial.mode,
                routeId: partial.routeId,
                direction: direction,
                stationLabel: partial.stationLabel,
                directionLabel: partial.directionLabel,
                totalCount: partial.summaryCount + partial.rawCount,
                recentObservationCount: partial.rawCount,
                score: combined,
                source: source
            )
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.totalCount != rhs.totalCount { return lhs.totalCount > rhs.totalCount }
                return lhs.id < rhs.id
            }
            .prefix(5)
            .map { $0 }
    }

    private func rawObservationScore(
        observation: MobilityProfile.RouteObservation,
        weekday: Int,
        hour: Int
    ) -> Double {
        let ageDays = max(0, clock.now.timeIntervalSince(observation.recordedAt) / 86_400)
        let recency = max(0, 3 - ageDays / 14)
        let weekdayBoost = observation.weekday == weekday ? 2.0 : 0
        let hourBoost = max(0, 3 - Double(hourDistance(hour, observation.hour)))
        return 1 + recency + weekdayBoost + hourBoost
    }

    private func summaryPatternScore(
        pattern: MobilityProfileSummary.RoutePattern,
        weekday: Int,
        hour: Int
    ) -> Double {
        guard pattern.totalCount > 0 else { return 0 }
        let totalDouble = Double(pattern.totalCount)
        let weekdayFraction = Double(pattern.weekdayCounts[String(weekday)] ?? 0) / totalDouble
        let hourCount = (-2...2).reduce(0) { acc, offset in
            let h = ((hour + offset) % 24 + 24) % 24
            return acc + (pattern.hourCounts[String(h)] ?? 0)
        }
        let hourFraction = Double(hourCount) / totalDouble
        let countSignal = log(totalDouble + 1)
        return countSignal * (0.3 + weekdayFraction * 1.5 + hourFraction * 1.5)
    }

    private func coverageScore(profile: MobilityProfile) -> Double {
        let rawCount = profile.observations.count + profile.routeObservations.count
        let summaryCount = profile.summary.consumedObservationCount + profile.summary.consumedRouteObservationCount
        let total = max(rawCount, summaryCount)
        guard total > 0 else { return 0 }
        return min(1, Double(total) / 50)
    }

    private func confidenceScore(
        direction: CommuteDirection,
        profile: MobilityProfile,
        motion: MotionContext?,
        departure: DepartureAnalysis,
        candidates: [LocalMobilityPrediction.RouteCandidate]
    ) -> Double {
        var score: Double = 0
        switch departure.match {
        case .insideLearnedWindow: score += 0.45
        case .nearLearnedWindow: score += 0.3
        case .fallbackWindow: score += 0.15
        case .outsideLearnedWindow: score += 0.05
        case .noLearnedWindow: score += 0
        }
        if departure.sampleCount >= 3 { score += 0.1 }
        if departure.sampleCount >= 10 { score += 0.05 }
        if !candidates.isEmpty { score += 0.15 }
        if let topScore = candidates.first?.score, topScore > 6 { score += 0.1 }
        switch motion {
        case .walking, .running: score += 0.1
        case .automotive, .cycling: score += 0.05
        default: break
        }
        return min(1, max(0, score))
    }

    private func buildReasonText(
        direction: CommuteDirection,
        context: CommuteContext,
        motion: MotionContext?,
        departure: DepartureAnalysis,
        candidate: LocalMobilityPrediction.RouteCandidate?
    ) -> String {
        var parts: [String] = []
        switch context {
        case .atHome: parts.append("At home")
        case .atWork: parts.append("At work")
        case .elsewhere: parts.append("Out and about")
        case .unknown: parts.append("Place unknown")
        }
        if let motion {
            switch motion {
            case .walking: parts.append("walking")
            case .running: parts.append("running")
            case .stationary: parts.append("still")
            case .cycling: parts.append("on a bike")
            case .automotive: parts.append("in a vehicle")
            case .unknown: break
            }
        }
        switch departure.match {
        case .insideLearnedWindow:
            parts.append("inside the learned departure window")
        case .nearLearnedWindow:
            parts.append("close to a learned departure")
        case .fallbackWindow:
            parts.append("in the typical commute hours")
        case .outsideLearnedWindow:
            parts.append("outside the usual departure window")
        case .noLearnedWindow:
            parts.append("no learned departure window yet")
        }

        let directionLabel = direction.label.lowercased()
        var sentence = parts.joined(separator: ", ").capitalized
        sentence += "; predicting \(directionLabel)."
        if let candidate {
            sentence += " Best learned match: \(routeDescription(candidate))."
        }
        return sentence
    }

    private func routeDescription(_ candidate: LocalMobilityPrediction.RouteCandidate) -> String {
        switch candidate.mode {
        case .train:
            let line = LineColor(rawValue: candidate.routeId)?.displayName ?? candidate.routeId
            if let label = candidate.directionLabel, !label.isEmpty {
                return "\(line) toward \(label)"
            }
            return line
        case .bus:
            if let label = candidate.directionLabel, !label.isEmpty {
                return "Bus #\(candidate.routeId) \(label)"
            }
            return "Bus #\(candidate.routeId)"
        case .metra:
            return "Metra \(candidate.routeId)"
        }
    }

    private func isWeekday(_ date: Date) -> Bool {
        isWeekday(weekday: clock.calendar.component(.weekday, from: date))
    }

    private func isWeekday(weekday: Int) -> Bool {
        (2...6).contains(weekday)
    }

    private func hourDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let raw = abs(lhs - rhs)
        return min(raw, 24 - raw)
    }
}
