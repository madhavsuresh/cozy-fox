import Foundation
import Observation
import TransitCache
import TransitDomain
import TransitModels

@MainActor
@Observable
final class DepartureLadderDebugViewModel {
    enum Status: Sendable, Equatable {
        case ready
        case missingHome
        case missingWork
        case missingPinnedLine
        case noNearbyStationOnLine
        case noLiveData
    }

    private(set) var ladder: DepartureLadder?
    private(set) var status: Status = .missingHome
    private(set) var boardingStationName: String?
    private(set) var alightingStationName: String?

    private let stationResolver = NearestStationResolver(maxDistanceMeters: 5_000)
    private let adapter = DepartureLadderSnapshotAdapter()
    private let builder = DepartureLadderBuilder()

    func rebuild(
        snapshot: TransitSnapshot,
        prefs: UserRoutePreferences,
        anchors: CommuteAnchors,
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date = .now
    ) {
        guard let home = anchors.home else {
            status = .missingHome
            ladder = nil
            return
        }
        guard let work = anchors.work else {
            status = .missingWork
            ladder = nil
            return
        }
        guard let line = pinnedLine(from: prefs) else {
            status = .missingPinnedLine
            ladder = nil
            return
        }

        let homeOrigin: (lat: Double, lon: Double) = (home.latitude, home.longitude)
        let workOrigin: (lat: Double, lon: Double) = (work.latitude, work.longitude)

        guard let boarding = stationResolver.nearest(onLine: line, to: homeOrigin) else {
            status = .noNearbyStationOnLine
            ladder = nil
            return
        }
        guard let alighting = stationResolver.nearest(onLine: line, to: workOrigin),
              alighting.id != boarding.id else {
            status = .noNearbyStationOnLine
            ladder = nil
            return
        }

        boardingStationName = boarding.name
        alightingStationName = alighting.name

        walkingResolver.ensureFresh(origin: homeOrigin, station: boarding)
        let homeWalkSeconds: TimeInterval = walkingResolver
            .cached(origin: homeOrigin, stationId: boarding.id)?.expectedTravelTime
            ?? haversineWalkSeconds(from: homeOrigin, to: (boarding.latitude, boarding.longitude), walkSpeedEstimate: walkSpeedEstimate)

        let finalMileSeconds = haversineWalkSeconds(
            from: (alighting.latitude, alighting.longitude),
            to: workOrigin,
            walkSpeedEstimate: walkSpeedEstimate
        )

        let stationDistanceMeters = haversineMeters(
            from: (boarding.latitude, boarding.longitude),
            to: (alighting.latitude, alighting.longitude)
        )
        let inVehicleSeconds = stationToStationSeconds(metersStraightLine: stationDistanceMeters)

        let liveDepartures = adapter.liveTrainDepartures(
            from: snapshot,
            line: line,
            stationId: boarding.id,
            now: now
        )
        let feedState = adapter.feedState(from: snapshot, now: now)

        if liveDepartures.isEmpty && feedState != .fresh {
            status = .noLiveData
            ladder = nil
            return
        }

        let candidate = LadderCandidateSpec(
            title: "\(line.displayName) — \(boarding.name)",
            mode: .ctaTrain,
            routeIdentifier: line.rawValue,
            direction: nil,
            boardingPoint: .station(systemRef: String(boarding.id), name: boarding.name, lineHint: line.rawValue),
            alightingPoint: .station(systemRef: String(alighting.id), name: alighting.name, lineHint: line.rawValue),
            inVehicleSeconds: inVehicleSeconds,
            inVehicleSigmaSeconds: max(60, inVehicleSeconds * 0.12),
            finalMileSeconds: finalMileSeconds,
            finalMileSigmaSeconds: max(30, finalMileSeconds * 0.12),
            scheduleHeadwaySeconds: 600,
            liveDepartures: liveDepartures,
            feedState: feedState
        )

        let walkFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval = { _, _ in homeWalkSeconds }

        ladder = builder.build(
            destinationTitle: work.label,
            origin: .anchor(.home),
            snapshot: snapshot,
            candidates: [candidate],
            walkSpeedEstimate: walkSpeedEstimate,
            walkingTimeFetcher: walkFetcher
        )
        status = .ready
    }

    private func pinnedLine(from prefs: UserRoutePreferences) -> LineColor? {
        if let pinned = prefs.pinnedLine { return pinned }
        return prefs.trains.first?.line
    }

    private func haversineMeters(from origin: (lat: Double, lon: Double), to dest: (lat: Double, lon: Double)) -> Double {
        let R: Double = 6_371_000
        let lat1 = origin.lat * .pi / 180
        let lat2 = dest.lat * .pi / 180
        let dLat = (dest.lat - origin.lat) * .pi / 180
        let dLon = (dest.lon - origin.lon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * atan2(sqrt(a), sqrt(1 - a))
    }

    private func haversineWalkSeconds(
        from origin: (lat: Double, lon: Double),
        to dest: (lat: Double, lon: Double),
        walkSpeedEstimate: WalkSpeedEstimate
    ) -> TimeInterval {
        let meters = haversineMeters(from: origin, to: dest)
        let basePaceSecondsPerMeter: Double = 0.78
        let ratio = walkSpeedEstimate.confidentRatio() ?? 1.0
        return meters * basePaceSecondsPerMeter * ratio
    }

    private func stationToStationSeconds(metersStraightLine: Double) -> TimeInterval {
        let avgGroundSpeedMps: Double = 12
        let stopPenaltyPerKm: Double = 25
        let km = metersStraightLine / 1000
        return metersStraightLine / avgGroundSpeedMps + km * stopPenaltyPerKm
    }
}
