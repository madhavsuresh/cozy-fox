import Foundation
import TransitCache
import TransitModels

/// App-side stitcher for lightweight commute-leg timing. It pairs semantic
/// region exits with observed boardings or destination-anchor entry, then
/// persists only route identity + durations into `MobilityProfile`.
@MainActor
final class CommuteLegTracker {
    private static let pendingExpiry: TimeInterval = 90 * 60

    private struct PendingLeg: Sendable {
        let direction: CommuteDirection
        let originAnchor: MobilityProfile.CommuteLegObservation.AnchorKind
        let destinationAnchor: MobilityProfile.CommuteLegObservation.AnchorKind
        let startedAt: Date
    }

    private struct RouteSnapshot: Sendable {
        let mode: MobilityProfile.CommuteLegObservation.Mode
        let routeId: String?
        let stopId: String?
        let stopLabel: String?
    }

    private var pendingLeg: PendingLeg?
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func recordRegionExit(direction: CommuteDirection, at date: Date) {
        pendingLeg = PendingLeg(
            direction: direction,
            originAnchor: originAnchor(for: direction),
            destinationAnchor: destinationAnchor(for: direction),
            startedAt: date
        )
    }

    func recordBoarding(
        stationId: Int,
        observedAt: Date,
        routePreferences: UserRoutePreferences,
        stationCatalog: [LStation] = LStationCatalog.all
    ) {
        guard let pending = validPending(at: observedAt) else { return }
        let elapsed = observedAt.timeIntervalSince(pending.startedAt)
        let station = stationCatalog.first { $0.id == stationId }
        let routeId = routePreferences.pinnedLine?.rawValue
            ?? singleServedLine(at: station)?.rawValue

        recordObservation(
            pending: pending,
            route: RouteSnapshot(
                mode: .train,
                routeId: routeId,
                stopId: String(stationId),
                stopLabel: station?.name
            ),
            accessSeconds: elapsed,
            totalSeconds: nil,
            quality: .observedBoarding,
            at: observedAt
        )
        pendingLeg = nil
    }

    func recordAnchorEntry(
        context: CommuteContext,
        at date: Date,
        routePreferences: UserRoutePreferences
    ) {
        guard let pending = validPending(at: date) else { return }
        guard anchorKind(for: context) == pending.destinationAnchor else { return }
        guard let route = routeSnapshot(from: routePreferences) else {
            pendingLeg = nil
            return
        }
        let elapsed = date.timeIntervalSince(pending.startedAt)
        recordObservation(
            pending: pending,
            route: route,
            accessSeconds: elapsed,
            totalSeconds: elapsed,
            quality: .inferred,
            at: date
        )
        pendingLeg = nil
    }

    private func validPending(at date: Date) -> PendingLeg? {
        guard let pendingLeg else { return nil }
        let elapsed = date.timeIntervalSince(pendingLeg.startedAt)
        guard elapsed > 0, elapsed <= Self.pendingExpiry else {
            self.pendingLeg = nil
            return nil
        }
        return pendingLeg
    }

    private func recordObservation(
        pending: PendingLeg,
        route: RouteSnapshot,
        accessSeconds: TimeInterval,
        totalSeconds: TimeInterval?,
        quality: MobilityProfile.CommuteLegObservation.SampleQuality,
        at date: Date
    ) {
        var profile = preferences.loadMobilityProfile()
        profile.recordCommuteLegObservation(
            direction: pending.direction,
            mode: route.mode,
            routeId: route.routeId,
            stopId: route.stopId,
            stopLabel: route.stopLabel,
            originAnchor: pending.originAnchor,
            destinationAnchor: pending.destinationAnchor,
            accessSeconds: accessSeconds,
            totalSeconds: totalSeconds,
            sampleQuality: quality,
            at: date,
            calendar: Self.chicagoCalendar
        )
        preferences.saveMobilityProfile(profile)
    }

    private func routeSnapshot(from prefs: UserRoutePreferences) -> RouteSnapshot? {
        if let trip = prefs.plannedTripPin {
            if let train = trip.train {
                return RouteSnapshot(
                    mode: .train,
                    routeId: train.line.rawValue,
                    stopId: train.stationId.map(String.init),
                    stopLabel: train.stationName
                )
            }
            if let bus = trip.bus {
                return RouteSnapshot(
                    mode: .bus,
                    routeId: bus.route,
                    stopId: bus.stopId.map(String.init),
                    stopLabel: bus.stopName
                )
            }
            if let metra = trip.metra {
                return RouteSnapshot(
                    mode: .metra,
                    routeId: metra.routeId,
                    stopId: metra.stationId,
                    stopLabel: metra.stationName
                )
            }
        }

        if let line = prefs.pinnedLine {
            return RouteSnapshot(
                mode: .train,
                routeId: line.rawValue,
                stopId: prefs.pinnedStationId.map(String.init),
                stopLabel: nil
            )
        }
        if let route = prefs.pinnedBusRoute {
            return RouteSnapshot(
                mode: .bus,
                routeId: route,
                stopId: prefs.pinnedBusStopId.map(String.init),
                stopLabel: nil
            )
        }
        if let route = prefs.pinnedMetraRoute {
            return RouteSnapshot(
                mode: .metra,
                routeId: route,
                stopId: prefs.pinnedMetraStationId,
                stopLabel: nil
            )
        }
        return nil
    }

    private func singleServedLine(at station: LStation?) -> LineColor? {
        guard let station, station.servedLines.count == 1 else { return nil }
        return station.servedLines.first
    }

    private func originAnchor(
        for direction: CommuteDirection
    ) -> MobilityProfile.CommuteLegObservation.AnchorKind {
        switch direction {
        case .toWork: return .home
        case .toHome: return .work
        case .anytime: return .unknown
        }
    }

    private func destinationAnchor(
        for direction: CommuteDirection
    ) -> MobilityProfile.CommuteLegObservation.AnchorKind {
        switch direction {
        case .toWork: return .work
        case .toHome: return .home
        case .anytime: return .unknown
        }
    }

    private func anchorKind(
        for context: CommuteContext
    ) -> MobilityProfile.CommuteLegObservation.AnchorKind {
        switch context {
        case .atHome: return .home
        case .atWork: return .work
        case .elsewhere: return .custom
        case .unknown: return .unknown
        }
    }

    private static var chicagoCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar
    }
}
