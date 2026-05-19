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

    /// Mode for human-powered legs of the journey — applies symmetrically to
    /// both the first mile (origin → boarding) and the last mile
    /// (alighting → destination). Transfer walks between transit legs stay
    /// on foot regardless.
    enum MileMode: String, Sendable, Equatable {
        case walk
        case bike

        var legMode: LegMode {
            switch self {
            case .walk: .walk
            case .bike: .divvyClassic
            }
        }

        /// Time-budget-preserving scaling for candidate-search radii. A 1.5 km
        /// bus stop is ~20 min at walking pace and ~7.5 min at biking pace; the
        /// rider's implicit time budget is the same either way, so the radius
        /// should grow by the pace ratio (~0.78 s/m ÷ ~0.30 s/m ≈ 2.6×) when
        /// biking. Empirical anchor: TCRP Report 95 and Pucher/Buehler's
        /// bike-and-ride catchment work peg cycling access radius at 2-3× a
        /// walking baseline, so 2.6× sits in the middle of the field rather
        /// than being made up.
        var radiusMultiplier: Double {
            switch self {
            case .walk: 1.0
            case .bike: 2.6
            }
        }
    }

    private(set) var ladder: DepartureLadder?
    private(set) var status: Status = .missingHome
    private(set) var candidateSummaries: [String] = []
    /// Mirrors how the destination was chosen so the card can label it and
    /// expose an unpin affordance for user-pinned trips.
    private(set) var destinationSource: DestinationSource = .defaultHomeWork
    /// Set whenever the target resolver runs, so the destination label stays
    /// visible during `noCandidates` (and any other empty-ladder state where
    /// we still know where the user intended to go).
    private(set) var resolvedDestinationTitle: String?

    enum DestinationSource: Sendable, Equatable {
        /// Resolved from `prefs.plannedTripPin` — the user picked it.
        case plannedTrip
        /// Resolved from `prefs.autoPinnedDirection` — the local predictor.
        case autopin
        /// Fallback: no pin, no autopin direction.
        case defaultHomeWork
    }

    /// Walking-paced radii. Bike mode multiplies each by `MileMode.radiusMultiplier`
    /// so distant lines that were unreachable on foot become candidates.
    private let baseTrainRadius: Double = 5_000
    private let baseMetraRadius: Double = 30_000
    private let baseBusRadius: Double = 1_500
    private let baseIntercampusRadius: Double = 2_000

    private func trainResolver(_ mode: MileMode) -> NearestStationResolver {
        NearestStationResolver(maxDistanceMeters: baseTrainRadius * mode.radiusMultiplier)
    }
    private func metraResolver(_ mode: MileMode) -> NearestMetraStationResolver {
        NearestMetraStationResolver(maxDistanceMeters: baseMetraRadius * mode.radiusMultiplier)
    }
    private func busResolver(_ mode: MileMode) -> NearestBusStopResolver {
        NearestBusStopResolver(maxDistanceMeters: baseBusRadius * mode.radiusMultiplier)
    }
    private func intercampusResolver(_ mode: MileMode) -> NearestIntercampusStopResolver {
        NearestIntercampusStopResolver(maxDistanceMeters: baseIntercampusRadius * mode.radiusMultiplier)
    }

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
        bikeInventory: BikeInventorySnapshot = .empty,
        mileMode: MileMode = .walk,
        now: Date = .now
    ) {
        guard let home = anchors.home else {
            status = .missingHome
            ladder = nil
            candidateSummaries = []
            resolvedDestinationTitle = nil
            return
        }
        guard let work = anchors.work else {
            status = .missingWork
            ladder = nil
            candidateSummaries = []
            resolvedDestinationTitle = nil
            return
        }

        let target = resolveTarget(prefs: prefs, home: home, work: work)
        let origin = target.origin
        let destination = target.destination
        destinationSource = target.source
        resolvedDestinationTitle = target.destinationTitle

        var specs: [LadderCandidateSpec] = []
        var summaries: [String] = []
        var walkSecondsByBoardingKey: [String: TimeInterval] = [:]

        // CTA trains — pinned line first, then any other tracked preferences heading the right way
        for spec in trainSpecs(prefs: prefs, snapshot: snapshot, origin: origin, destination: destination, excludedTrainDirection: target.excludedTrainDirection, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, mileMode: mileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("\(spec.modeLabel): \(spec.candidate.title)")
        }

        // Metra — planned-trip legs first, then the daily pinned Metra route
        for spec in metraSpecs(prefs: prefs, snapshot: snapshot, origin: origin, destination: destination, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, mileMode: mileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Metra: \(spec.candidate.title)")
        }

        // CTA Bus — planned-trip bus legs first, then the daily pinned bus
        for spec in busSpecs(prefs: prefs, snapshot: snapshot, origin: origin, destination: destination, walkingResolver: walkingResolver, walkSpeedEstimate: walkSpeedEstimate, mileMode: mileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Bus: \(spec.candidate.title)")
        }

        // Intercampus shuttle — planned-trip legs first, then daily pinned direction
        for spec in intercampusSpecs(prefs: prefs, snapshot: snapshot, origin: origin, destination: destination, walkSpeedEstimate: walkSpeedEstimate, mileMode: mileMode, now: now) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Intercampus: \(spec.candidate.title)")
        }

        // Full Divvy ride — walk to a nearby station with bikes, ride to a
        // station near the destination, walk in. Always considered (separate
        // from the mile-mode toggle, which is about how you reach a transit
        // stop).
        if let spec = divvySpec(
            bikeInventory: bikeInventory,
            origin: origin,
            destination: destination,
            walkingResolver: walkingResolver,
            walkSpeedEstimate: walkSpeedEstimate,
            now: now
        ) {
            walkSecondsByBoardingKey[boardingKey(spec)] = spec.walkSeconds
            specs.append(spec.candidate)
            summaries.append("Divvy: \(spec.candidate.title)")
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
            destinationTitle: target.destinationTitle,
            origin: target.originPoint,
            destinationPoint: target.destinationPoint,
            snapshot: snapshot,
            candidates: specs,
            walkSpeedEstimate: walkSpeedEstimate,
            walkingTimeFetcher: walkFetcher,
            clock: SystemClock()
        )
        ladder = built
        status = .ready

        let originLabel = target.originLabel
        let store = logStore
        Task.detached(priority: .background) {
            await store.appendLadder(built, origin: originLabel)
        }
    }

    // MARK: - Target resolution

    /// Chooses the origin/destination the ladder is plotting. A user-entered
    /// `plannedTripPin` wins; otherwise we follow `autoPinnedDirection`.
    /// Fallback is the historical home → work pair.
    private struct LadderTarget {
        let origin: (lat: Double, lon: Double)
        let originPoint: JourneyPoint
        let originLabel: String
        let destination: (lat: Double, lon: Double)
        let destinationPoint: JourneyPoint
        let destinationTitle: String
        /// Excluded commute direction when filtering `prefs.trains`. `nil` means
        /// keep every entry (used for custom planned-trip destinations where
        /// the toHome/toWork buckets don't map cleanly).
        let excludedTrainDirection: CommuteDirection?
        let source: DestinationSource
    }

    private func resolveTarget(
        prefs: UserRoutePreferences,
        home: CommuteAnchors.Anchor,
        work: CommuteAnchors.Anchor
    ) -> LadderTarget {
        func toWork(source: DestinationSource) -> LadderTarget {
            LadderTarget(
                origin: (home.latitude, home.longitude),
                originPoint: .anchor(.home),
                originLabel: home.label,
                destination: (work.latitude, work.longitude),
                destinationPoint: .anchor(.work),
                destinationTitle: work.label,
                excludedTrainDirection: .toHome,
                source: source
            )
        }
        func toHome(source: DestinationSource) -> LadderTarget {
            LadderTarget(
                origin: (work.latitude, work.longitude),
                originPoint: .anchor(.work),
                originLabel: work.label,
                destination: (home.latitude, home.longitude),
                destinationPoint: .anchor(.home),
                destinationTitle: home.label,
                excludedTrainDirection: .toWork,
                source: source
            )
        }

        if let trip = prefs.plannedTripPin,
           let lat = trip.destination.latitude,
           let lon = trip.destination.longitude {
            switch trip.destination.kind {
            case .home:
                return toHome(source: .plannedTrip)
            case .work:
                return toWork(source: .plannedTrip)
            case .custom:
                return LadderTarget(
                    origin: (home.latitude, home.longitude),
                    originPoint: .anchor(.home),
                    originLabel: home.label,
                    destination: (lat, lon),
                    destinationPoint: .namedPlace(
                        title: trip.destination.title,
                        subtitle: trip.destination.subtitle,
                        latitude: lat,
                        longitude: lon
                    ),
                    destinationTitle: trip.destination.title,
                    excludedTrainDirection: nil,
                    source: .plannedTrip
                )
            }
        }

        if prefs.autoPinnedDirection == .toHome {
            return toHome(source: .autopin)
        }
        if prefs.autoPinnedDirection == .toWork {
            return toWork(source: .autopin)
        }
        return toWork(source: .defaultHomeWork)
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
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        excludedTrainDirection: CommuteDirection?,
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        mileMode: MileMode,
        now: Date
    ) -> [ResolvedSpec] {
        var seen: Set<String> = []
        var out: [ResolvedSpec] = []

        // Build a deduped list: planned-trip legs first (the user explicitly
        // chose them for this trip), then the daily pinned line, then any
        // remaining tracked train preferences not going the wrong way.
        var attempts: [(line: LineColor, stationId: Int?, directionLabel: String?)] = []
        for leg in prefs.plannedTripPin?.trainLegs ?? [] {
            attempts.append((leg.line, leg.stationId, leg.destinationName))
        }
        if let pinned = prefs.pinnedLine {
            attempts.append((pinned, prefs.pinnedStationId, nil))
        }
        for entry in prefs.trains {
            if let excluded = excludedTrainDirection, entry.direction == excluded { continue }
            attempts.append((entry.line, entry.mapId, entry.directionLabel))
        }

        let resolver = trainResolver(mileMode)
        for attempt in attempts {
            guard let boarding = boardingStation(line: attempt.line, preferredStationId: attempt.stationId, near: origin, resolver: resolver) else { continue }
            guard let alighting = resolver.nearest(onLine: attempt.line, to: destination), alighting.id != boarding.id else { continue }
            let key = "train-\(attempt.line.rawValue)-\(boarding.id)"
            if !seen.insert(key).inserted { continue }

            walkingResolver.ensureFresh(origin: origin, station: boarding)
            let walkSeconds = boardingLegSeconds(
                from: origin,
                to: (boarding.latitude, boarding.longitude),
                cachedWalkSeconds: walkingResolver.cached(origin: origin, stationId: boarding.id)?.expectedTravelTime,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )

            let alightingDistanceToDestination = haversineMeters(from: (alighting.latitude, alighting.longitude), to: destination)
            let detected = transferDetector.detect(
                sourceLine: attempt.line,
                boardingStation: boarding,
                directAlighting: alighting,
                home: origin,
                work: destination,
                snapshot: snapshot,
                now: now
            )

            if detected == nil && alightingDistanceToDestination > unreachableAlightingMeters {
                continue
            }

            let finalAlighting = detected?.finalAlighting ?? alighting
            let finalMile = finalMileSeconds(
                from: (finalAlighting.latitude, finalAlighting.longitude),
                to: destination,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
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
                boardingMode: mileMode.legMode,
                finalMileSeconds: finalMile,
                finalMileSigmaSeconds: max(30, finalMile * 0.12),
                finalMileMode: mileMode.legMode,
                scheduleHeadwaySeconds: 600,
                liveDepartures: live,
                feedState: feed,
                transfer: transferLeg
            )
            out.append(ResolvedSpec(modeLabel: "L", candidate: candidate, walkSeconds: walkSeconds))
        }
        return out
    }

    private func boardingStation(line: LineColor, preferredStationId: Int?, near origin: (lat: Double, lon: Double), resolver: NearestStationResolver) -> LStation? {
        if let id = preferredStationId, let pinned = LStationCatalog.byId[id], pinned.servedLines.contains(line) {
            return pinned
        }
        return resolver.nearest(onLine: line, to: origin)
    }

    private func matchingStop(route: String, direction: String?, near origin: (lat: Double, lon: Double), resolver: NearestBusStopResolver) -> BusStop? {
        let perDirection = resolver.nearestStopsPerDirection(
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

    private func metraSpecs(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        mileMode: MileMode,
        now: Date
    ) -> [ResolvedSpec] {
        // Planned-trip Metra legs first, then the daily pinned Metra route.
        var attempts: [(routeId: String, stationId: String?, directionId: Int?, destinationLabel: String?)] = []
        for leg in prefs.plannedTripPin?.metraLegs ?? [] {
            attempts.append((leg.routeId, leg.stationId, leg.directionId, leg.destinationName))
        }
        if let routeId = prefs.pinnedMetraRoute {
            attempts.append((routeId, prefs.pinnedMetraStationId, prefs.pinnedMetraDirectionId, prefs.pinnedMetraDestination))
        }
        guard !attempts.isEmpty else { return [] }

        let resolver = metraResolver(mileMode)
        var seen: Set<String> = []
        var out: [ResolvedSpec] = []

        for attempt in attempts {
            let boardingStation: MetraStation? = {
                if let id = attempt.stationId, let s = MetraStationCatalog.station(id: id) { return s }
                return resolver.closestStations(onRoute: attempt.routeId, to: origin, limit: 1).first?.station
            }()
            guard let boarding = boardingStation else { continue }
            guard let alighting = resolver.closestStations(onRoute: attempt.routeId, to: destination, limit: 1).first?.station,
                  alighting.id != boarding.id else { continue }

            let key = "metra-\(attempt.routeId)-\(boarding.id)"
            if !seen.insert(key).inserted { continue }

            walkingResolver.ensureFresh(origin: origin, metraStation: boarding)
            let walkSeconds = boardingLegSeconds(
                from: origin,
                to: (boarding.latitude, boarding.longitude),
                cachedWalkSeconds: walkingResolver
                    .cached(origin: origin, destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: boarding.id), mode: .walking)?.expectedTravelTime,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )

            let finalMile = finalMileSeconds(
                from: (alighting.latitude, alighting.longitude),
                to: destination,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )
            let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
            let inVehicle = stationToStationSeconds(meters: dist, modeSpeedMps: 22, stopPenaltyPerKm: 8)

            let live = adapter.liveMetraDepartures(from: snapshot, routeId: attempt.routeId, stationId: boarding.id, directionId: attempt.directionId, now: now)
            let feed = adapter.feedState(fetchedAt: snapshot.metraFetchedAt, now: now, freshnessTtlSeconds: 300)

            out.append(ResolvedSpec(
                modeLabel: "Metra",
                candidate: LadderCandidateSpec(
                    title: "Metra \(attempt.routeId) — \(boarding.name)",
                    mode: .metra,
                    routeIdentifier: attempt.routeId,
                    direction: attempt.destinationLabel,
                    boardingPoint: .station(systemRef: "Metra:\(boarding.id)", name: boarding.name, lineHint: attempt.routeId),
                    alightingPoint: .station(systemRef: "Metra:\(alighting.id)", name: alighting.name, lineHint: attempt.routeId),
                    inVehicleSeconds: inVehicle,
                    inVehicleSigmaSeconds: max(60, inVehicle * 0.10),
                    boardingMode: mileMode.legMode,
                    finalMileSeconds: finalMile,
                    finalMileSigmaSeconds: max(30, finalMile * 0.12),
                    finalMileMode: mileMode.legMode,
                    scheduleHeadwaySeconds: 1800,
                    liveDepartures: live,
                    feedState: feed
                ),
                walkSeconds: walkSeconds
            ))
        }
        return out
    }

    // MARK: - CTA Bus

    private func busSpecs(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        mileMode: MileMode,
        now: Date
    ) -> [ResolvedSpec] {
        // Planned-trip legs first (the user explicitly picked them), then the
        // daily pinned bus route. Deduped by (route, boarding stop id).
        var attempts: [(route: String, stopId: Int?, directionLabel: String?)] = []
        for leg in prefs.plannedTripPin?.busLegs ?? [] {
            attempts.append((leg.route, leg.stopId, leg.directionLabel))
        }
        if let route = prefs.pinnedBusRoute {
            attempts.append((route, prefs.pinnedBusStopId, prefs.pinnedBusDirection))
        }
        guard !attempts.isEmpty else { return [] }

        let resolver = busResolver(mileMode)
        var seen: Set<String> = []
        var out: [ResolvedSpec] = []

        for attempt in attempts {
            let routeCatalog = BusStopCatalog.stops(onRoute: attempt.route)
            let boardingStop: BusStop? = {
                if let id = attempt.stopId, let s = routeCatalog.first(where: { $0.id == id }) { return s }
                return matchingStop(route: attempt.route, direction: attempt.directionLabel, near: origin, resolver: resolver)
            }()
            guard let boarding = boardingStop else { continue }
            guard let alighting = matchingStop(route: attempt.route, direction: attempt.directionLabel ?? boarding.directionLabel, near: destination, resolver: resolver),
                  alighting.id != boarding.id else { continue }

            let key = "bus-\(attempt.route)-\(boarding.id)"
            if !seen.insert(key).inserted { continue }

            walkingResolver.ensureFresh(origin: origin, stop: boarding)
            let walkSeconds = boardingLegSeconds(
                from: origin,
                to: (boarding.latitude, boarding.longitude),
                cachedWalkSeconds: walkingResolver
                    .cached(origin: origin, destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: boarding.id), mode: .walking)?.expectedTravelTime,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )

            let finalMile = finalMileSeconds(
                from: (alighting.latitude, alighting.longitude),
                to: destination,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )
            let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
            let inVehicle = stationToStationSeconds(meters: dist, modeSpeedMps: 6, stopPenaltyPerKm: 30)

            let live = adapter.liveBusDepartures(from: snapshot, route: attempt.route, stopId: boarding.id, directionLabel: attempt.directionLabel, now: now)
            let feed = adapter.feedState(fetchedAt: snapshot.busesFetchedAt, now: now)

            out.append(ResolvedSpec(
                modeLabel: "Bus",
                candidate: LadderCandidateSpec(
                    title: "Bus \(attempt.route) — \(boarding.name)",
                    mode: .ctaBus,
                    routeIdentifier: attempt.route,
                    direction: attempt.directionLabel,
                    boardingPoint: .stop(systemRef: "Bus:\(boarding.id)", name: boarding.name, latitude: boarding.latitude, longitude: boarding.longitude),
                    alightingPoint: .stop(systemRef: "Bus:\(alighting.id)", name: alighting.name, latitude: alighting.latitude, longitude: alighting.longitude),
                    inVehicleSeconds: inVehicle,
                    inVehicleSigmaSeconds: max(60, inVehicle * 0.18),
                    boardingMode: mileMode.legMode,
                    finalMileSeconds: finalMile,
                    finalMileSigmaSeconds: max(30, finalMile * 0.12),
                    finalMileMode: mileMode.legMode,
                    scheduleHeadwaySeconds: 720,
                    liveDepartures: live,
                    feedState: feed
                ),
                walkSeconds: walkSeconds
            ))
        }
        return out
    }

    // MARK: - Intercampus

    private func intercampusSpecs(
        prefs: UserRoutePreferences,
        snapshot: TransitSnapshot,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        walkSpeedEstimate: WalkSpeedEstimate,
        mileMode: MileMode,
        now: Date
    ) -> [ResolvedSpec] {
        // Planned-trip Intercampus legs first, then the daily pinned
        // intercampus direction (gated on `includeIntercampus`).
        var attempts: [(direction: IntercampusDirection, stopId: String?)] = []
        for leg in prefs.plannedTripPin?.intercampusLegs ?? [] {
            attempts.append((leg.direction, leg.stopId))
        }
        if prefs.includeIntercampus, let direction = prefs.pinnedIntercampusDirection {
            attempts.append((direction, prefs.pinnedIntercampusStopId))
        }
        guard !attempts.isEmpty else { return [] }

        let resolver = intercampusResolver(mileMode)
        var seen: Set<String> = []
        var out: [ResolvedSpec] = []

        for attempt in attempts {
            let boardingStop: IntercampusStop? = {
                if let id = attempt.stopId, let s = IntercampusCatalog.stop(id: id) { return s }
                return resolver.closestStops(direction: attempt.direction, to: origin, limit: 1).first?.stop
            }()
            guard let boarding = boardingStop else { continue }
            guard let alighting = resolver.closestStops(direction: attempt.direction, to: destination, limit: 1).first?.stop,
                  alighting.id != boarding.id else { continue }

            let key = "intercampus-\(attempt.direction.rawValue)-\(boarding.id)"
            if !seen.insert(key).inserted { continue }

            let walkSeconds = boardingLegSeconds(
                from: origin,
                to: (boarding.latitude, boarding.longitude),
                cachedWalkSeconds: nil,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )
            let finalMile = finalMileSeconds(
                from: (alighting.latitude, alighting.longitude),
                to: destination,
                walkSpeedEstimate: walkSpeedEstimate,
                mode: mileMode
            )
            let dist = haversineMeters(from: (boarding.latitude, boarding.longitude), to: (alighting.latitude, alighting.longitude))
            let scheduledInVehicle = IntercampusCatalog.scheduledTravelSeconds(
                direction: attempt.direction,
                from: boarding.id,
                to: alighting.id,
                after: now
            )
            let inVehicle = scheduledInVehicle ?? stationToStationSeconds(meters: dist, modeSpeedMps: 14, stopPenaltyPerKm: 6)
            let inVehicleSigma = scheduledInVehicle == nil
                ? max(60, inVehicle * 0.20)
                : max(90, inVehicle * 0.12)

            let live = adapter.liveIntercampusDepartures(from: snapshot, stopId: boarding.id, direction: attempt.direction, now: now)
            let feed = adapter.feedState(fetchedAt: snapshot.intercampusFetchedAt, now: now, freshnessTtlSeconds: 180)

            out.append(ResolvedSpec(
                modeLabel: "Intercampus",
                candidate: LadderCandidateSpec(
                    title: "Intercampus \(attempt.direction.label) — \(boarding.name)",
                    mode: .intercampus,
                    routeIdentifier: "intercampus-\(attempt.direction.rawValue)",
                    direction: attempt.direction.label,
                    boardingPoint: .stop(systemRef: "Intercampus:\(boarding.id)", name: boarding.name, latitude: boarding.latitude, longitude: boarding.longitude),
                    alightingPoint: .stop(systemRef: "Intercampus:\(alighting.id)", name: alighting.name, latitude: alighting.latitude, longitude: alighting.longitude),
                    inVehicleSeconds: inVehicle,
                    inVehicleSigmaSeconds: inVehicleSigma,
                    boardingMode: mileMode.legMode,
                    finalMileSeconds: finalMile,
                    finalMileSigmaSeconds: max(30, finalMile * 0.12),
                    finalMileMode: mileMode.legMode,
                    scheduleHeadwaySeconds: 1200,
                    liveDepartures: live,
                    feedState: feed
                ),
                walkSeconds: walkSeconds
            ))
        }
        return out
    }

    // MARK: - Full Divvy ride

    /// Max walking distance home/work → Divvy station for a full-bike
    /// candidate. Tighter than transit-stop radii because both ends of the
    /// trip add walking; a 1.5 km walk each side wipes out the bike's
    /// advantage over straight transit.
    private let divvyAccessRadiusMeters: Double = 800

    /// Build a "ride Divvy door-to-door" candidate: walk to the nearest
    /// station with a bike, ride to the nearest station with an open dock
    /// near work, walk in. Bike has no schedule, so we synthesize a single
    /// live departure timed so `leaveBy ≈ now` and the row sits in the
    /// ladder alongside the timed transit options.
    ///
    /// The cycling leg uses MapKit `.cycling` directions (via
    /// `WalkingDistanceResolver`); on cache miss we fall back to a
    /// haversine paced by `bikePaceSecondsPerMeter`. Bike-route *quality*
    /// scoring (Mellow / CDOT infrastructure layer) would slot in here —
    /// see `docs/BIKE_ROUTING.md` for the parked design.
    private func divvySpec(
        bikeInventory: BikeInventorySnapshot,
        origin: (lat: Double, lon: Double),
        destination: (lat: Double, lon: Double),
        walkingResolver: WalkingDistanceResolver,
        walkSpeedEstimate: WalkSpeedEstimate,
        now: Date
    ) -> ResolvedSpec? {
        guard !bikeInventory.stations.isEmpty else { return nil }
        guard let boarding = nearestStationWithBike(
            to: origin,
            stations: bikeInventory.stations,
            maxMeters: divvyAccessRadiusMeters
        ) else { return nil }
        guard let alighting = nearestStationWithDock(
            to: destination,
            stations: bikeInventory.stations,
            maxMeters: divvyAccessRadiusMeters
        ), alighting.id != boarding.id else { return nil }

        // Walk to the boarding dock.
        walkingResolver.ensureFresh(origin: origin, divvyStation: boarding, modes: [.walking])
        let walkToDockSeconds = boardingLegSeconds(
            from: origin,
            to: (boarding.latitude, boarding.longitude),
            cachedWalkSeconds: walkingResolver
                .cached(origin: origin, divvyStationId: boarding.id, mode: .walking)?.expectedTravelTime,
            walkSpeedEstimate: walkSpeedEstimate,
            mode: .walk
        )

        // Cycle from boarding dock to alighting dock. Cache key origin =
        // boarding-station coord, which is stable across runs.
        let boardingCoord = (lat: boarding.latitude, lon: boarding.longitude)
        walkingResolver.ensureFresh(origin: boardingCoord, divvyStation: alighting, modes: [.cycling])
        let cycleMeters = haversineMeters(from: boardingCoord, to: (alighting.latitude, alighting.longitude))
        let cachedCycle = walkingResolver
            .cached(origin: boardingCoord, divvyStationId: alighting.id, mode: .cycling)?.expectedTravelTime
        let rideSeconds = cachedCycle ?? cycleMeters * bikePaceSecondsPerMeter

        // Walk from alighting dock to the destination. No MapKit fetch — the
        // resolver's cache is keyed by anchor origins; "station → arbitrary
        // point" doesn't fit that shape, so we pace the haversine instead.
        let finalMileSeconds = finalMileSeconds(
            from: (alighting.latitude, alighting.longitude),
            to: destination,
            walkSpeedEstimate: walkSpeedEstimate,
            mode: .walk
        )

        // Pick the in-vehicle mode by what's actually available at the
        // boarding dock. Classic preferred if present (cheaper, no surge);
        // fall through to e-bike if it's the only option.
        let inVehicleMode: LegMode = boarding.classicBikesAvailable > 0 ? .divvyClassic : .divvyEBike

        // Synthesize one live "departure" so the builder produces a single
        // bike row at `leaveBy ≈ now`. The builder subtracts a conservative
        // boarding-walk + slack from `arrivalAt` to compute leaveBy, so we
        // bias the synthetic departure forward by the same amount.
        let walkSigma = max(30, walkToDockSeconds * 0.12)
        let conservativeBoard = walkToDockSeconds + 0.8416 * walkSigma
        let slackSeconds: TimeInterval = 60
        let departureAt = now.addingTimeInterval(conservativeBoard + slackSeconds + 5)
        let synthDeparture = LiveDeparture(
            arrivalAt: departureAt,
            isApproaching: true,
            isScheduled: false,
            toneHint: .strong
        )

        let title = "Divvy — \(boarding.name) → \(alighting.name)"
        return ResolvedSpec(
            modeLabel: "Divvy",
            candidate: LadderCandidateSpec(
                title: title,
                mode: inVehicleMode,
                routeIdentifier: "divvy",
                direction: nil,
                boardingPoint: .divvyStation(
                    stationId: boarding.id,
                    name: boarding.name,
                    latitude: boarding.latitude,
                    longitude: boarding.longitude
                ),
                alightingPoint: .divvyStation(
                    stationId: alighting.id,
                    name: alighting.name,
                    latitude: alighting.latitude,
                    longitude: alighting.longitude
                ),
                inVehicleSeconds: rideSeconds,
                // MapKit cycling ETA already accounts for typical traffic
                // delay on Chicago streets; 12% spread is roughly
                // symmetric with the transit candidates so risk
                // comparisons stay meaningful.
                inVehicleSigmaSeconds: max(60, rideSeconds * 0.12),
                boardingMode: .walk,
                finalMileSeconds: finalMileSeconds,
                finalMileSigmaSeconds: max(30, finalMileSeconds * 0.12),
                finalMileMode: .walk,
                scheduleHeadwaySeconds: nil,
                liveDepartures: [synthDeparture],
                feedState: .fresh
            ),
            walkSeconds: walkToDockSeconds
        )
    }

    /// Nearest renting Divvy station within `maxMeters` that has at least
    /// one bike (classic or e-bike).
    private func nearestStationWithBike(
        to origin: (lat: Double, lon: Double),
        stations: [BikeStation],
        maxMeters: Double
    ) -> BikeStation? {
        stations
            .filter { $0.isRenting && ($0.classicBikesAvailable + $0.eBikesAvailable) > 0 }
            .compactMap { station -> (BikeStation, Double)? in
                let d = haversineMeters(from: origin, to: (station.latitude, station.longitude))
                return d <= maxMeters ? (station, d) : nil
            }
            .min { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Nearest accepting Divvy station within `maxMeters` that has at least
    /// one open dock.
    private func nearestStationWithDock(
        to origin: (lat: Double, lon: Double),
        stations: [BikeStation],
        maxMeters: Double
    ) -> BikeStation? {
        stations
            .filter { $0.isReturning && $0.docksAvailable > 0 }
            .compactMap { station -> (BikeStation, Double)? in
                let d = haversineMeters(from: origin, to: (station.latitude, station.longitude))
                return d <= maxMeters ? (station, d) : nil
            }
            .min { $0.1 < $1.1 }
            .map(\.0)
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
        mode: MileMode
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

    /// Mirror of `finalMileSeconds` for the boarding leg. When walking we
    /// prefer the MapKit-cached walking time (which is street-routed); on
    /// cache miss or when biking we fall back to a haversine paced by mode.
    /// Biking deliberately skips the WalkSpeedEstimate ratio — that's a
    /// walking-only calibration.
    private func boardingLegSeconds(
        from origin: (lat: Double, lon: Double),
        to dest: (lat: Double, lon: Double),
        cachedWalkSeconds: TimeInterval?,
        walkSpeedEstimate: WalkSpeedEstimate,
        mode: MileMode
    ) -> TimeInterval {
        switch mode {
        case .walk:
            return cachedWalkSeconds
                ?? haversineWalkSeconds(from: origin, to: dest, walkSpeedEstimate: walkSpeedEstimate)
        case .bike:
            let meters = haversineMeters(from: origin, to: dest)
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
