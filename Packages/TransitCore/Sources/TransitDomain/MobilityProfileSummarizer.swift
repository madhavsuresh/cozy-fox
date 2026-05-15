import Foundation
import TransitModels

/// Folds raw `MobilityProfile.observations` and `routeObservations` into the
/// long-lived `MobilityProfile.summary`. Lets the app keep raw history short
/// (14 days) without losing the learned commute patterns.
///
/// The summarizer is purely additive: each refresh adds the observations
/// recorded *after* `summary.lastSummarizedAt`, never re-consumes old rows.
/// On first run (no `lastSummarizedAt` set), it folds in every observation
/// the profile currently holds, which migrates pre-summary profiles forward.
public struct MobilityProfileSummarizer: Sendable {
    public init() {}

    /// Returns a new profile with `summary` advanced to include any
    /// observations newer than the existing `lastSummarizedAt`. Idempotent for
    /// observations whose `recordedAt` is `<= lastSummarizedAt`.
    public func refresh(
        _ profile: MobilityProfile,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MobilityProfile {
        var updated = profile
        let cursor = profile.summary.lastSummarizedAt
        var summary = profile.summary

        let newObservations = profile.observations.filter { observation in
            guard let cursor else { return true }
            return observation.recordedAt > cursor
        }
        let newRouteObservations = profile.routeObservations.filter { observation in
            guard let cursor else { return true }
            return observation.recordedAt > cursor
        }
        let newCommuteLegObservations = profile.commuteLegObservations.filter { observation in
            guard let cursor else { return true }
            return observation.recordedAt > cursor
        }

        for observation in newObservations {
            fold(observation: observation, into: &summary)
        }
        for observation in newRouteObservations {
            fold(routeObservation: observation, into: &summary)
        }
        for observation in newCommuteLegObservations {
            summary.fold(commuteLegObservation: observation)
        }

        // Advance the cursor to the latest observation we consumed, or `now`
        // when there were no new rows so we don't keep re-scanning identical
        // histories on every refresh.
        let latestObservation = newObservations.map(\.recordedAt).max()
        let latestRouteObservation = newRouteObservations.map(\.recordedAt).max()
        let latestCommuteLegObservation = newCommuteLegObservations.map(\.recordedAt).max()
        let latest = [latestObservation, latestRouteObservation, latestCommuteLegObservation, cursor]
            .compactMap { $0 }
            .max()
        summary.lastSummarizedAt = max(latest ?? now, now)
        updated.summary = summary
        return updated
    }

    private func fold(
        observation: MobilityProfile.Observation,
        into summary: inout MobilityProfileSummary
    ) {
        guard let direction = observation.direction else { return }
        let onlyExitSources: Set<MobilityProfile.Observation.Source> = [.exitedHome, .exitedWork]
        guard onlyExitSources.contains(observation.source) else { return }

        let key = MobilityProfileSummary.departureKey(source: observation.source, direction: direction)
        var window = summary.departureWindows[key] ?? MobilityProfileSummary.DepartureWindow()
        let bucket = MobilityProfileSummary.DepartureWindow.key(
            weekday: observation.weekday,
            hour: observation.hour
        )
        window.weekdayHourCounts[bucket, default: 0] += 1
        window.totalCount += 1
        if let latest = window.latestSampleAt {
            window.latestSampleAt = max(latest, observation.recordedAt)
        } else {
            window.latestSampleAt = observation.recordedAt
        }
        summary.departureWindows[key] = window
        summary.consumedObservationCount += 1
    }

    private func fold(
        routeObservation observation: MobilityProfile.RouteObservation,
        into summary: inout MobilityProfileSummary
    ) {
        let originBucket = observation.origin?.bucketKey()
        let destinationBucket = observation.destination?.bucketKey()
        let weekdayKey = String(observation.weekday)
        let hourKey = String(observation.hour)

        var counted = false
        if let line = observation.line {
            updatePattern(
                summary: &summary,
                direction: observation.direction,
                mode: .train,
                routeId: line.rawValue,
                stationId: observation.stationId.map(String.init),
                directionLabel: observation.trainDestination,
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }
        if let route = observation.busRoute {
            updatePattern(
                summary: &summary,
                direction: observation.direction,
                mode: .bus,
                routeId: route,
                stationId: nil,
                directionLabel: observation.busDirection,
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }
        if let route = observation.metraRoute {
            updatePattern(
                summary: &summary,
                direction: observation.direction,
                mode: .metra,
                routeId: route,
                stationId: observation.metraStationId,
                directionLabel: observation.metraDirectionId.map(String.init),
                originBucket: originBucket,
                destinationBucket: destinationBucket,
                weekdayKey: weekdayKey,
                hourKey: hourKey,
                recordedAt: observation.recordedAt
            )
            counted = true
        }

        if counted {
            summary.consumedRouteObservationCount += 1
        }
    }

    private func updatePattern(
        summary: inout MobilityProfileSummary,
        direction: CommuteDirection,
        mode: MobilityProfileSummary.RoutePattern.Mode,
        routeId: String,
        stationId: String?,
        directionLabel: String?,
        originBucket: String?,
        destinationBucket: String?,
        weekdayKey: String,
        hourKey: String,
        recordedAt: Date
    ) {
        let key = MobilityProfileSummary.RoutePattern.key(
            direction: direction,
            mode: mode,
            routeId: routeId
        )
        var pattern = summary.routePatterns[key] ?? MobilityProfileSummary.RoutePattern(
            direction: direction,
            mode: mode,
            routeId: routeId,
            latestSampleAt: recordedAt
        )
        pattern.totalCount += 1
        pattern.weekdayCounts[weekdayKey, default: 0] += 1
        pattern.hourCounts[hourKey, default: 0] += 1
        if let stationId, !stationId.isEmpty {
            pattern.stationCounts[stationId, default: 0] += 1
        }
        if let directionLabel, !directionLabel.isEmpty {
            pattern.directionLabelCounts[directionLabel, default: 0] += 1
        }
        if let originBucket {
            pattern.originBucketCounts[originBucket, default: 0] += 1
        }
        if let destinationBucket {
            pattern.destinationBucketCounts[destinationBucket, default: 0] += 1
        }
        pattern.latestSampleAt = max(pattern.latestSampleAt, recordedAt)
        summary.routePatterns[key] = pattern
    }
}
