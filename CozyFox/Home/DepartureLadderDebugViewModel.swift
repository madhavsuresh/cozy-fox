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

    enum LastMileMode: String, Sendable, Equatable {
        case walk
        case bike

        var legMode: LegMode {
            switch self {
            case .walk: .walk
            case .bike: .divvyClassic
            }
        }
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
    private let transferDetector = TransferDetector()
    private let unreachableAlightingMeters: Double = 3_000
    private let logStore = JourneyPredictionLogStore()

    /// Effective walking pace, sec/m. ~1.28 m/s.
    private let walkPaceSecondsPerMeter: Double = 0.78
    /// Effective cycling pace, sec/m. ~3.3 m/s — slower than peak so that
    /// unlock/light/parking penalties on a short last-mile aren't ignored.
    private let bikePaceSecondsPerMeter: Double = 0.30

    func rebuild(
        snapshot: TransitSnapshot,
        prefs: UserRoutePreferences,
        anchors: CommuteAnchors,
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        lastMileMode: LastMileMode = .walk,
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
        for spec in trainSpecs(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, lastMileMode: lastMileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("\(spec.modeLabel): \(spec.candidate.title)")
        }

        // Metra
        if let spec = metraSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, lastMileMode: lastMileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Metra: \(spec.candidate.title)")
        }

        // CTA Bus
        if let spec = busSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, lastMileMode: lastMileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Bus: \(spec.candidate.title)")
        }

        // Intercampus shuttle
        if let spec = intercampusSpec(prefs: prefs, snapshot: snapshot, home: homeOrigin, work: workOrigin, walkSpeedEstimate: walkSpeedEstimate, lastMileMode: lastMileMode, now: now) {
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

        let built = builder.build(
            destinationTitle: work.label,
            origin: .anchor(.home),
            destinationPoint: .coordinate(latitude: work.latitude, longitude: work.longitude),
            snapshot: snapshot,
            candidates: specs,
            walkSpeedEstimate: walkSpeedEstimate,
            walkingTimeFetcher: walkFetcher,
            clock: SystemClock()
        )
        ladder = built
        status = .ready

        let originLabel = home.label
        let store = logStore
        Task.detached(priority: .background) {
            await store.appendLadder(built, origin: originLabel)
        }
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
        lastMileMode: LastMileMode,
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
            let detected = transferDetector.detect(
                sourceLine: attempt.line,
                boardingStation: boarding,
                directAlighting: alighting,
                home: home,
                work: work,
                snapshot: snapshot,
                now: now
            )

            if detected == nil && alightingDistanceToWork > unreachableAlightingMeters {
                continue
            }

            let finalAlighting = detected?.finalAlighting ?? alighting
            let finalMile = finalMileSeconds(
                from: (finalAlighting.latitude, finalAlighting.longitude),
                to: work,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: lastMileMode
            )

            let firstSegmentEnd = detected?.intermediate ?? alighting
            let stationDist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (firstSegmentEnd.latitude, firstSegmentEnd.longitude))
            let inVehicle = stationToStationSeconds(meters: stationDist, modeSpeedMps: 12, stopPenaltyPerKm: 25)

            let live = adapter.liveTrainDeparturesTowardAlighting(
                from: snapshot,
                line: attempt.line,
                boardingStation: boarding,
                alightingStation: firstSegmentEnd,
                now: now
            )
            let feed = adapter.feedState(fetchedAt: snapshot.trainsFetchedAt, now: now)

            let transferLeg: LadderTransferLeg? = detected.map { d in
                let live = adapter.liveTrainDeparturesTowardAlighting(
                    from: snapshot,
                    line: d.nextLine,
                    boardingStation: d.intermediate,
                    alightingStation: d.finalAlighting,
                    now: now
                )
                let feed = adapter.feedState(fetchedAt: snapshot.trainsFetchedAt, now: now)
                return LadderTransferLeg(
                    transferWalkSeconds: d.transferWalkSeconds,
                    transferWalkSigmaSeconds: 30,
                    nextMode: .ctaTrain,
                    nextRouteIdentifier: d.nextLine.rawValue,
                    nextDirection: nil,
                    nextBoardingPoint: .station(systemRef: "L:\(d.intermediate.id)", name: d.intermediate.name, lineHint: d.nextLine.rawValue),
                    nextAlightingPoint: .station(systemRef: "L:\(d.finalAlighting.id)", name: d.finalAlighting.name, lineHint: d.nextLine.rawValue),
                    nextInVehicleSeconds: d.nextInVehicleSeconds,
                    nextInVehicleSigmaSeconds: max(60, d.nextInVehicleSeconds * 0.15),
                    nextScheduleHeadwaySeconds: 600,
                    nextLiveDepartures: live,
                    nextFeedState: feed
                )
            }

            let title = detected == nil
                ? "\(attempt.line.displayName) — \(boarding.name)"
                : "\(attempt.line.displayName) → \(detected!.nextLine.displayName)"
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
                finalMileMode: lastMileMode.legMode,
                scheduleHeadwaySeconds: 600,
                liveDepartures: live,
                feedState: feed,
                transfer: transferLeg
            )
            out.append(ResolvedSpec(modeLabel: "L", candidate: candidate, walkSeconds: walkSeconds))
        }
        return out
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
        lastMileMode: LastMileMode,
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

        let finalMile = finalMileSeconds(
            from: (alighting.latitude, alighting.longitude),
            to: work,
            walkSpeedEstimate: walkSpeedEstimate,
            mode: lastMileMode
        )
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
                finalMileMode: lastMileMode.legMode,
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
        lastMileMode: LastMileMode,
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

        let finalMile = finalMileSeconds(
            from: (alighting.latitude, alighting.longitude),
            to: work,
            walkSpeedEstimate: walkSpeedEstimate,
            mode: lastMileMode
        )
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
                finalMileMode: lastMileMode.legMode,
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
        lastMileMode: LastMileMode,
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
        let finalMile = finalMileSeconds(
            from: (alighting.latitude, alighting.longitude),
            to: work,
            walkSpeedEstimate: walkSpeedEstimate,
            mode: lastMileMode
        )
        let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
        let scheduledInVehicle = IntercampusCatalog.scheduledTravelSeconds(
            direction: direction,
            from: boarding.id,
            to: alighting.id,
            after: now
        )
        let inVehicle = scheduledInVehicle ?? stationToStationSeconds(meters: dist, modeSpeedMps: 14, stopPenaltyPerKm: 6)
        let inVehicleSigma = scheduledInVehicle == nil
            ? max(60, inVehicle * 0.20)
            : max(90, inVehicle * 0.12)

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
                inVehicleSigmaSeconds: inVehicleSigma,
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                finalMileMode: lastMileMode.legMode,
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
        let ratio = walkSpeedEstimate.confidentRatio() ?? 1.0
        return meters * walkPaceSecondsPerMeter * ratio
    }

    /// Picks walking or cycling pace for the last-mile distance. Walking
    /// applies the user's `WalkSpeedEstimate`; biking uses a flat pace
    /// because the cycling estimate is anchor↔station-only and not
    /// reliable for arbitrary final-mile geometries yet.
    private func finalMileSeconds(
        from origin: (lat: Double, lon: Double),
        to dest: (lat: Double, lon: Double),
        walkSpeedEstimate: WalkSpeedEstimate,
        mode: LastMileMode
    ) -> TimeInterval {
        let meters = haversineMeters(from: origin, to: dest)
        switch mode {
        case .walk:
            let ratio = walkSpeedEstimate.confidentRatio() ?? 1.0
            return meters * walkPaceSecondsPerMeter * ratio
        case .bike:
            return meters * bikePaceSecondsPerMeter
        }
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
