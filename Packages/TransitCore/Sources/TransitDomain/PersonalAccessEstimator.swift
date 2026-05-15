import Foundation
import TransitModels

public struct PersonalAccessEstimate: Sendable, Hashable {
    public let medianSeconds: TimeInterval
    public let conservativeSeconds: TimeInterval
    public let sampleCount: Int
    public let confidence: Double

    public init(
        medianSeconds: TimeInterval,
        conservativeSeconds: TimeInterval,
        sampleCount: Int,
        confidence: Double
    ) {
        self.medianSeconds = medianSeconds
        self.conservativeSeconds = max(medianSeconds, conservativeSeconds)
        self.sampleCount = sampleCount
        self.confidence = min(1, max(0, confidence))
    }
}

public struct PersonalAccessEstimator: Sendable {
    public let profile: MobilityProfile
    public let now: Date
    public let calendar: Calendar

    public init(
        profile: MobilityProfile,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        self.profile = profile
        self.now = now
        self.calendar = calendar
    }

    public func estimate(
        direction: CommuteDirection,
        mode: MobilityProfile.CommuteLegObservation.Mode,
        routeId: String?,
        stopId: String?
    ) -> PersonalAccessEstimate? {
        let raw = matchingRaw(
            direction: direction,
            mode: mode,
            routeId: routeId,
            stopId: stopId
        )
        if raw.count >= 3 {
            return estimateFromRaw(raw)
        }

        let summaries = matchingSummaries(
            direction: direction,
            mode: mode,
            routeId: routeId,
            stopId: stopId
        )
        if let exact = summaries.first(where: { $0.totalCount >= 3 }) {
            return estimateFromSummary(exact)
        }
        if raw.count >= 2 {
            return estimateFromRaw(raw)
        }
        return summaries.first.map(estimateFromSummary)
    }

    private func matchingRaw(
        direction: CommuteDirection,
        mode: MobilityProfile.CommuteLegObservation.Mode,
        routeId: String?,
        stopId: String?
    ) -> [MobilityProfile.CommuteLegObservation] {
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        return profile.commuteLegObservations
            .filter { observation in
                observation.direction == direction
                    && observation.mode == mode
                    && routeMatches(observation.routeId, target: routeId)
                    && stopMatches(observation.stopId, target: stopId)
            }
            .sorted {
                let lhs = temporalDistance(weekday: $0.weekday, hour: $0.hour, targetWeekday: weekday, targetHour: hour)
                let rhs = temporalDistance(weekday: $1.weekday, hour: $1.hour, targetWeekday: weekday, targetHour: hour)
                if lhs != rhs { return lhs < rhs }
                return $0.recordedAt > $1.recordedAt
            }
    }

    private func matchingSummaries(
        direction: CommuteDirection,
        mode: MobilityProfile.CommuteLegObservation.Mode,
        routeId: String?,
        stopId: String?
    ) -> [MobilityProfileSummary.CommuteLegPattern] {
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        return profile.summary.commuteLegPatterns.values
            .filter { pattern in
                pattern.direction == direction
                    && pattern.mode == mode
                    && routeMatches(pattern.routeId, target: routeId)
                    && stopMatches(pattern.stopId, target: stopId)
            }
            .sorted { lhs, rhs in
                let lhsScore = patternScore(lhs, weekday: weekday, hour: hour)
                let rhsScore = patternScore(rhs, weekday: weekday, hour: hour)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.latestSampleAt > rhs.latestSampleAt
            }
    }

    private func estimateFromRaw(
        _ observations: [MobilityProfile.CommuteLegObservation]
    ) -> PersonalAccessEstimate {
        let samples = observations.prefix(12).map(\.accessSeconds).sorted()
        let median = median(samples)
        let stddev = standardDeviation(samples)
        let conservative = median + max(45, stddev)
        return PersonalAccessEstimate(
            medianSeconds: median,
            conservativeSeconds: conservative,
            sampleCount: samples.count,
            confidence: min(1, Double(samples.count) / 8)
        )
    }

    private func estimateFromSummary(
        _ pattern: MobilityProfileSummary.CommuteLegPattern
    ) -> PersonalAccessEstimate {
        let stddev = pattern.accessStandardDeviationSeconds ?? 60
        return PersonalAccessEstimate(
            medianSeconds: pattern.accessMeanSeconds,
            conservativeSeconds: pattern.accessMeanSeconds + max(45, stddev),
            sampleCount: pattern.totalCount,
            confidence: min(1, Double(pattern.totalCount) / 12)
        )
    }

    private func routeMatches(_ value: String?, target: String?) -> Bool {
        guard let target, !target.isEmpty else { return true }
        return value == target
    }

    private func stopMatches(_ value: String?, target: String?) -> Bool {
        guard let target, !target.isEmpty else { return true }
        return value == target
    }

    private func patternScore(
        _ pattern: MobilityProfileSummary.CommuteLegPattern,
        weekday: Int,
        hour: Int
    ) -> Double {
        let total = max(1, pattern.totalCount)
        let weekdayFraction = Double(pattern.weekdayCounts[String(weekday)] ?? 0) / Double(total)
        let hourFraction = (-2...2).reduce(0.0) { acc, offset in
            let h = ((hour + offset) % 24 + 24) % 24
            return acc + Double(pattern.hourCounts[String(h)] ?? 0) / Double(total)
        }
        let ageDays = max(0, now.timeIntervalSince(pattern.latestSampleAt) / 86_400)
        return log(Double(total) + 1) + weekdayFraction + hourFraction + max(0, 1 - ageDays / 60)
    }

    private func temporalDistance(
        weekday: Int,
        hour: Int,
        targetWeekday: Int,
        targetHour: Int
    ) -> Int {
        let dayDistance = min(abs(weekday - targetWeekday), 7 - abs(weekday - targetWeekday))
        let rawHour = abs(hour - targetHour)
        let hourDistance = min(rawHour, 24 - rawHour)
        return dayDistance * 24 + hourDistance
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[mid - 1] + values[mid]) / 2
        }
        return values[mid]
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}
