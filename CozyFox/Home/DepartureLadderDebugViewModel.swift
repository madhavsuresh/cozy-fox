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
        case noCandidates
    }

    private(set) var ladder: DepartureLadder?
    private(set) var status: Status = .missingHome
    private(set) var candidateSummaries: [String] = []

    private let trainResolver = NearestStationResolver(maxDistanceMeters: 5_000)
    private let metraResolver = NearestMetraStationResolver(maxDistanceMeters: 30_000)
    private let busResolver = NearestBusStopResolver(maxDistanceMeters: 1_500)
    private let intercampusResolver = NearestIntercampusStopResolver(maxDistanceMeters: 2_000)
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
            candidateSummaries = []
            return
        }
        guard let work = anchors.work else {
            status = .missingWork
            ladder = nil
            candidateSummaries = []
            return
        }

        let homeOrigin: (lat: Double, lon: Double) = (home.latitude, home.longitude)
        let workOrigin: (lat: Double, lon: Double) = (work.latitude, work.longitude)

        var specs: [LadderCandidateSpec] = []
        var summaries: [String] = []
        var walkSecondsByBoardingKey: [String: TimeInterval] = [:]

        // CTA trains — pinned line first, then any other tracked preferences heading toward work
        for spec in trainSpecs(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("\(spec.modeLabel): \(spec.candidate.title)")
        }

        // Metra
        if let spec = metraSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Metra: \(spec.candidate.title)")
        }

        // CTA Bus
        if let spec = busSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Bus: \(spec.candidate.title)")
        }

        // Intercampus shuttle
        if let spec = intercampusSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkSpeedEstimate: walkSpeedEstimate, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Intercampus: \(spec.candidate.title)")
        }

        guard !specs.isEmpty else {
            status = .noCandidates
            ladder = nil
            candidateSummaries = []
            return
        }

        candidateSummaries = summaries

        let walkLookup = walkSecondsByBoardingKey
        let walkFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval = { _, to in
            walkLookup[journeyPointKey(to)] ?? 300
        }

        ladder = builder.build(
            destinationTitle: work.label,
            origin: .anchor(.home),
            destinationPoint: .coordinate(latitude: work.latitude, longitude: work.longitude),
            snapshot: snapshot,
            candidates: specs,
            walkSpeedEstimate: walkSpeedEstimate,
            walkingTimeFetcher: walkFetcher,
            clock: SystemClock()
        )
        status = .ready
    }

    // MARK: - CTA trains

    private struct ResolvedSpec {
        let modeLabel: String
        let candidate: LadderCandidateSpec
        let walkSeconds: TimeInterval
    }

    private func trainSpecs(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> [ResolvedSpec] {
        var seen: Set<String> = []
        var out: [ResolvedSpec] = []

        // Build a deduped list: pinned line first, then explicit train preferences heading toward work
        var attempts: [(line: LineColor, stationId: Int?, directionLabel: String?)] = []
        if let pinned = prefs.pinnedLine {
            attempts.append((pinned, prefs.pinnedStationId, nil))
        }
        for entry in prefs.trains where entry.direction != .toHome {
            attempts.append((entry.line, entry.mapId, entry.directionLabel))
        }

        for attempt in attempts {
            guard let boarding = boardingStation(line: attempt.line, preferredStationId: attempt.stationId, near: home) else { continue }
            guard let alighting = trainResolver.nearest(onLine: attempt.line, to: work), alighting.id != boarding.id else { continue }
            let key = "train-\(attempt.line.rawValue)-\(boarding.id)"
            if !seen.insert(key).inserted { continue }

            walkingResolver.ensureFresh(origin: home, station: boarding)
            let walkSeconds = walkingResolver
                .cached(origin: home, stationId: boarding.id)?.expectedTravelTime
                ?? haversineWalkSeconds(from: home, to: (boarding.latitude, boarding.longitude), walkSpeedEstimate: walkSpeedEstimate)

            let alightingDistanceToWork = haversineMeters(from: (alighting.latitude, alighting.longitude), to: work)
            let transfer = detectTransfer(
                from: attempt.line,
                boarding: boarding,
                directAlighting: alighting,
                directAlightingDistanceToWork: alightingDistanceToWork,
                home: home,
                work: work,
                snapshot: snapshot,
                walkSpeedEstimate: walkSpeedEstimate,
                now: now
            )

            let finalAlighting = transfer?.finalAlighting ?? alighting
            let finalMile = haversineWalkSeconds(from: (finalAlighting.latitude, finalAlighting.longitude), to: work, walkSpeedEstimate: walkSpeedEstimate)

            let firstSegmentEnd = transfer?.intermediate ?? alighting
            let stationDist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (firstSegmentEnd.latitude, firstSegmentEnd.longitude))
            let inVehicle = stationToStationSeconds(meters: stationDist, modeSpeedMps: 12, stopPenaltyPerKm: 25)

            let live = adapter.liveTrainDepartures(from: snapshot, line: attempt.line, stationId: boarding.id, now: now)
            let feed = adapter.feedState(fetchedAt: snapshot.trainsFetchedAt, now: now)
            let title = transfer == nil
                ? "\(attempt.line.displayName) — \(boarding.name)"
                : "\(attempt.line.displayName) → \(transfer!.nextLine.displayName)"
            let candidate = LadderCandidateSpec(
                title: title,
                mode: .ctaTrain,
                routeIdentifier: attempt.line.rawValue,
                direction: attempt.directionLabel,
                boardingPoint: .station(systemRef: "L:\(boarding.id)", name: boarding.name, lineHint: attempt.line.rawValue),
                alightingPoint: .station(systemRef: "L:\(firstSegmentEnd.id)", name: firstSegmentEnd.name, lineHint: attempt.line.rawValue),
                inVehicleSeconds: inVehicle,
                inVehicleSigmaSeconds: max(60, inVehicle * 0.12),
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                scheduleHeadwaySeconds: 600,
                liveDepartures: live,
                feedState: feed,
                transfer: transfer?.leg
            )
            out.append(ResolvedSpec(modeLabel: "L", candidate: candidate, walkSeconds: walkSeconds))
        }
        return out
    }

    private struct DetectedTransfer {
        let intermediate: LStation
        let finalAlighting: LStation
        let nextLine: LineColor
        let leg: LadderTransferLeg
    }

    private func detectTransfer(
        from sourceLine: LineColor,
        boarding: LStation,
        directAlighting: LStation,
        directAlightingDistanceToWork: Double,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        snapshot: TransitSnapshot,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> DetectedTransfer? {
        if directAlightingDistanceToWork < 1500 { return nil }

        var best: (saving: Double, detected: DetectedTransfer)?

        for otherLine in LineColor.allCases where otherLine != sourceLine {
            guard let nearestOnOther = LStationCatalog.stations(onLine: otherLine).min(by: {
                haversineMeters(from: ($0.latitude, $0.longitude), to: work) < haversineMeters(from: ($1.latitude, $1.longitude), to: work)
            }) else { continue }
            let otherDistance = haversineMeters(from: (nearestOnOther.latitude, nearestOnOther.longitude), to: work)
            let saving = directAlightingDistanceToWork - otherDistance
            if saving < 500 { continue }

            let candidatesByDistance = LStationCatalog.all
                .filter { $0.servedLines.contains(sourceLine) && $0.servedLines.contains(otherLine) && $0.id != boarding.id }
                .map { (station: $0, distToFinal: haversineMeters(from: ($0.latitude, $0.longitude), to: (nearestOnOther.latitude, nearestOnOther.longitude))) }
                .sorted { $0.distToFinal < $1.distToFinal }
            guard let transferStation = candidatesByDistance.first?.station else { continue }

            let onPath = isStationBetween(home: home, work: work, station: transferStation)
            guard onPath else { continue }

            let secondLegMeters = haversineMeters(from: (transferStation.latitude, transferStation.longitude), to: (nearestOnOther.latitude, nearestOnOther.longitude))
            let secondLegSeconds = stationToStationSeconds(meters: secondLegMeters, modeSpeedMps: 12, stopPenaltyPerKm: 25)
            let transferWalk = haversineWalkSeconds(
                from: (transferStation.latitude, transferStation.longitude),
                to: (transferStation.latitude, transferStation.longitude),
                walkSpeedEstimate: walkSpeedEstimate
            ) + 90

            let live = adapter.liveTrainDepartures(from: snapshot, line: otherLine, stationId: transferStation.id, now: now)
            let feed = adapter.feedState(fetchedAt: snapshot.trainsFetchedAt, now: now)
            let leg = LadderTransferLeg(
                transferWalkSeconds: transferWalk,
                transferWalkSigmaSeconds: 30,
                nextMode: .ctaTrain,
                nextRouteIdentifier: otherLine.rawValue,
                nextDirection: nil,
                nextBoardingPoint: .station(systemRef: "L:\(transferStation.id)", name: transferStation.name, lineHint: otherLine.rawValue),
                nextAlightingPoint: .station(systemRef: "L:\(nearestOnOther.id)", name: nearestOnOther.name, lineHint: otherLine.rawValue),
                nextInVehicleSeconds: secondLegSeconds,
                nextInVehicleSigmaSeconds: max(60, secondLegSeconds * 0.15),
                nextScheduleHeadwaySeconds: 600,
                nextLiveDepartures: live,
                nextFeedState: feed
            )

            let detected = DetectedTransfer(
                intermediate: transferStation,
                finalAlighting: nearestOnOther,
                nextLine: otherLine,
                leg: leg
            )
            if best == nil || saving > best!.saving {
                best = (saving, detected)
            }
        }
        return best?.detected
    }

    private func isStationBetween(home: (lat: Double, lon: Double), work: (lat: Double, lon: Double), station: LStation) -> Bool {
        let homeToWork = haversineMeters(from: home, to: work)
        let homeToStation = haversineMeters(from: home, to: (station.latitude, station.longitude))
        let stationToWork = haversineMeters(from: (station.latitude, station.longitude), to: work)
        return homeToStation + stationToWork < homeToWork * 1.4
    }

    private func boardingStation(line: LineColor, preferredStationId: Int?, near origin: (lat: Double, lon: Double)) -> LStation? {
        if let id = preferredStationId, let pinned = LStationCatalog.byId[id], pinned.servedLines.contains(line) {
            return pinned
        }
        return trainResolver.nearest(onLine: line, to: origin)
    }

    private func matchingStop(route: String, direction: String?, near origin: (lat: Double, lon: Double)) -> BusStop? {
        let perDirection = busResolver.nearestStopsPerDirection(
            onRoute: route,
            to: origin,
            limitPerDirection: 1,
            catalog: BusStopCatalog.stops(onRoute: route)
        )
        if let direction {
            return perDirection.first(where: { $0.stop.directionLabel.caseInsensitiveCompare(direction) == .orderedSame })?.stop
                ?? perDirection.first?.stop
        }
        return perDirection.first?.stop
    }

    // MARK: - Metra

    private func metraSpec(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> ResolvedSpec? {
        guard let routeId = prefs.pinnedMetraRoute else { return nil }
        let boardingStation: MetraStation? = {
            if let id = prefs.pinnedMetraStationId, let s = MetraStationCatalog.station(id: id) { return s }
            return metraResolver.closestStations(onRoute: routeId, to: home, limit: 1).first?.station
        }()
        guard let boarding = boardingStation else { return nil }
        guard let alighting = metraResolver.closestStations(onRoute: routeId, to: work, limit: 1).first?.station,
              alighting.id != boarding.id else { return nil }

        walkingResolver.ensureFresh(origin: home, metraStation: boarding)
        let walkSeconds = walkingResolver
            .cached(origin: home, destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: boarding.id), mode: .walking)?.expectedTravelTime
            ?? haversineWalkSeconds(from: home, to: (boarding.latitude, boarding.longitude), walkSpeedEstimate: walkSpeedEstimate)

        let finalMile = haversineWalkSeconds(from: (alighting.latitude, alighting.longitude), to: work, walkSpeedEstimate: walkSpeedEstimate)
        let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
        let inVehicle = stationToStationSeconds(meters: dist, modeSpeedMps: 22, stopPenaltyPerKm: 8)

        let live = adapter.liveMetraDepartures(from: snapshot, routeId: routeId, stationId: boarding.id, directionId: prefs.pinnedMetraDirectionId, now: now)
        let feed = adapter.feedState(fetchedAt: snapshot.metraFetchedAt, now: now, freshnessTtlSeconds: 300)

        return ResolvedSpec(
            modeLabel: "Metra",
            candidate: LadderCandidateSpec(
                title: "Metra \(routeId) — \(boarding.name)",
                mode: .metra,
                routeIdentifier: routeId,
                direction: prefs.pinnedMetraDestination,
                boardingPoint: .station(systemRef: "Metra:\(boarding.id)", name: boarding.name, lineHint: routeId),
                alightingPoint: .station(systemRef: "Metra:\(alighting.id)", name: alighting.name, lineHint: routeId),
                inVehicleSeconds: inVehicle,
                inVehicleSigmaSeconds: max(60, inVehicle * 0.10),
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                scheduleHeadwaySeconds: 1800,
                liveDepartures: live,
                feedState: feed
            ),
            walkSeconds: walkSeconds
        )
    }

    // MARK: - CTA Bus

    private func busSpec(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> ResolvedSpec? {
        guard let route = prefs.pinnedBusRoute else { return nil }
        let directionLabel = prefs.pinnedBusDirection
        let routeCatalog = BusStopCatalog.stops(onRoute: route)
        let boardingStop: BusStop? = {
            if let id = prefs.pinnedBusStopId, let s = routeCatalog.first(where: { $0.id == id }) { return s }
            return matchingStop(route: route, direction: directionLabel, near: home)
        }()
        guard let boarding = boardingStop else { return nil }
        guard let alighting = matchingStop(route: route, direction: directionLabel ?? boarding.directionLabel, near: work),
              alighting.id != boarding.id else { return nil }

        walkingResolver.ensureFresh(origin: home, stop: boarding)
        let walkSeconds = walkingResolver
            .cached(origin: home, destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: boarding.id), mode: .walking)?.expectedTravelTime
            ?? haversineWalkSeconds(from: home, to: (boarding.latitude, boarding.longitude), walkSpeedEstimate: walkSpeedEstimate)

        let finalMile = haversineWalkSeconds(from: (alighting.latitude, alighting.longitude), to: work, walkSpeedEstimate: walkSpeedEstimate)
        let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
        let inVehicle = stationToStationSeconds(meters: dist, modeSpeedMps: 6, stopPenaltyPerKm: 30)

        let live = adapter.liveBusDepartures(from: snapshot, route: route, stopId: boarding.id, directionLabel: directionLabel, now: now)
        let feed = adapter.feedState(fetchedAt: snapshot.busesFetchedAt, now: now)

        return ResolvedSpec(
            modeLabel: "Bus",
            candidate: LadderCandidateSpec(
                title: "Bus \(route) — \(boarding.name)",
                mode: .ctaBus,
                routeIdentifier: route,
                direction: directionLabel,
                boardingPoint: .stop(systemRef: "Bus:\(boarding.id)", name: boarding.name, latitude: boarding.latitude, longitude: boarding.longitude),
                alightingPoint: .stop(systemRef: "Bus:\(alighting.id)", name: alighting.name, latitude: alighting.latitude, longitude: alighting.longitude),
                inVehicleSeconds: inVehicle,
                inVehicleSigmaSeconds: max(60, inVehicle * 0.18),
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                scheduleHeadwaySeconds: 720,
                liveDepartures: live,
                feedState: feed
            ),
            walkSeconds: walkSeconds
        )
    }

    // MARK: - Intercampus

    private func intercampusSpec(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> ResolvedSpec? {
        guard prefs.includeIntercampus, let direction = prefs.pinnedIntercampusDirection else { return nil }
        let boardingStop: IntercampusStop? = {
            if let id = prefs.pinnedIntercampusStopId, let s = IntercampusCatalog.stop(id: id) { return s }
            return intercampusResolver.closestStops(direction: direction, to: home, limit: 1).first?.stop
        }()
        guard let boarding = boardingStop else { return nil }
        let oppositeDirection: IntercampusDirection = direction == .northbound ? .southbound : .northbound
        _ = oppositeDirection
        guard let alighting = intercampusResolver.closestStops(direction: direction, to: work, limit: 1).first?.stop,
              alighting.id != boarding.id else { return nil }

        let walkSeconds = haversineWalkSeconds(from: home, to: (boarding.latitude, boarding.longitude), walkSpeedEstimate: walkSpeedEstimate)
        let finalMile = haversineWalkSeconds(from: (alighting.latitude, alighting.longitude), to: work, walkSpeedEstimate: walkSpeedEstimate)
        let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
        let inVehicle = stationToStationSeconds(meters: dist, modeSpeedMps: 14, stopPenaltyPerKm: 6)

        let live = adapter.liveIntercampusDepartures(from: snapshot, stopId: boarding.id, direction: direction, now: now)
        let feed = adapter.feedState(fetchedAt: snapshot.intercampusFetchedAt, now: now, freshnessTtlSeconds: 180)

        return ResolvedSpec(
            modeLabel: "Intercampus",
            candidate: LadderCandidateSpec(
                title: "Intercampus \(direction.label) — \(boarding.name)",
                mode: .intercampus,
                routeIdentifier: "intercampus-\(direction.rawValue)",
                direction: direction.label,
                boardingPoint: .stop(systemRef: "Intercampus:\(boarding.id)", name: boarding.name, latitude: boarding.latitude, longitude: boarding.longitude),
                alightingPoint: .stop(systemRef: "Intercampus:\(alighting.id)", name: alighting.name, latitude: alighting.latitude, longitude: alighting.longitude),
                inVehicleSeconds: inVehicle,
                inVehicleSigmaSeconds: max(60, inVehicle * 0.20),
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                scheduleHeadwaySeconds: 1200,
                liveDepartures: live,
                feedState: feed
            ),
            walkSeconds: walkSeconds
        )
    }

    // MARK: - Helpers

    private func boardingKey(_ spec: ResolvedSpec) -> String {
        journeyPointKey(spec.candidate.boardingPoint)
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

    private func stationToStationSeconds(meters: Double, modeSpeedMps: Double, stopPenaltyPerKm: TimeInterval) -> TimeInterval {
        let km = meters / 1000
        return meters / modeSpeedMps + km * stopPenaltyPerKm
    }
}

private func journeyPointKey(_ point: JourneyPoint) -> String {
    switch point {
    case .anchor(let kind): "anchor:\(kind.rawValue)"
    case .coordinate(let lat, let lon): "coord:\(lat),\(lon)"
    case .stop(let ref, _, _, _): "stop:\(ref)"
    case .station(let ref, _, _): "station:\(ref)"
    case .divvyStation(let id, _, _, _): "divvy:\(id)"
    case .namedPlace(let title, _, _, _): "place:\(title)"
    }
}
