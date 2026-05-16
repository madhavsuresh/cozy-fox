import Foundation
import TransitCache
import TransitModels

public struct TransferDetector: Sendable {
    public let savingThresholdMeters: Double
    public let directAlightingDistanceTrigger: Double
    public let pathDeviationTolerance: Double
    public let recentArrivalWindowSeconds: TimeInterval
    public let defaultTransferWalkSeconds: TimeInterval
    public let defaultInVehicleSpeedMps: Double
    public let stopPenaltyPerKmSeconds: TimeInterval

    public init(
        savingThresholdMeters: Double = 500,
        directAlightingDistanceTrigger: Double = 1_500,
        pathDeviationTolerance: Double = 1.4,
        recentArrivalWindowSeconds: TimeInterval = 30 * 60,
        defaultTransferWalkSeconds: TimeInterval = 90,
        defaultInVehicleSpeedMps: Double = 12,
        stopPenaltyPerKmSeconds: TimeInterval = 25
    ) {
        self.savingThresholdMeters = max(0, savingThresholdMeters)
        self.directAlightingDistanceTrigger = max(0, directAlightingDistanceTrigger)
        self.pathDeviationTolerance = max(1, pathDeviationTolerance)
        self.recentArrivalWindowSeconds = max(0, recentArrivalWindowSeconds)
        self.defaultTransferWalkSeconds = max(0, defaultTransferWalkSeconds)
        self.defaultInVehicleSpeedMps = max(1, defaultInVehicleSpeedMps)
        self.stopPenaltyPerKmSeconds = max(0, stopPenaltyPerKmSeconds)
    }

    public struct Detected: Sendable, Hashable {
        public let intermediate: LStation
        public let finalAlighting: LStation
        public let nextLine: LineColor
        public let transferWalkSeconds: TimeInterval
        public let nextInVehicleSeconds: TimeInterval

        public init(
            intermediate: LStation,
            finalAlighting: LStation,
            nextLine: LineColor,
            transferWalkSeconds: TimeInterval,
            nextInVehicleSeconds: TimeInterval
        ) {
            self.intermediate = intermediate
            self.finalAlighting = finalAlighting
            self.nextLine = nextLine
            self.transferWalkSeconds = transferWalkSeconds
            self.nextInVehicleSeconds = nextInVehicleSeconds
        }
    }

    public func detect(
        sourceLine: LineColor,
        boardingStation: LStation,
        directAlighting: LStation,
        home: (lat: Double, lon: Double),
        work: (lat: Double, lon: Double),
        snapshot: TransitSnapshot,
        now: Date = .now,
        catalog: [LStation] = LStationCatalog.all
    ) -> Detected? {
        let directDistanceToWork = haversineMeters(
            from: (directAlighting.latitude, directAlighting.longitude),
            to: work
        )
        guard directDistanceToWork >= directAlightingDistanceTrigger else { return nil }

        var best: (saving: Double, detected: Detected)?

        for otherLine in LineColor.allCases where otherLine != sourceLine {
            guard isLineServiceViable(otherLine, snapshot: snapshot, now: now) else { continue }

            let stationsOnOther = catalog.filter { $0.servedLines.contains(otherLine) }
            guard let nearestOnOther = stationsOnOther.min(by: {
                haversineMeters(from: ($0.latitude, $0.longitude), to: work)
                    < haversineMeters(from: ($1.latitude, $1.longitude), to: work)
            }) else { continue }

            let otherDistance = haversineMeters(from: (nearestOnOther.latitude, nearestOnOther.longitude), to: work)
            let saving = directDistanceToWork - otherDistance
            if saving < savingThresholdMeters { continue }

            let shared = catalog
                .filter { $0.servedLines.contains(sourceLine) && $0.servedLines.contains(otherLine) && $0.id != boardingStation.id }
                .map { (station: $0, distToFinal: haversineMeters(from: ($0.latitude, $0.longitude), to: (nearestOnOther.latitude, nearestOnOther.longitude))) }
                .sorted { $0.distToFinal < $1.distToFinal }
            guard let transferStation = shared.first?.station else { continue }
            guard isStationBetween(home: home, work: work, station: transferStation) else { continue }

            let secondLegMeters = haversineMeters(
                from: (transferStation.latitude, transferStation.longitude),
                to: (nearestOnOther.latitude, nearestOnOther.longitude)
            )
            let secondLegSeconds = secondLegMeters / defaultInVehicleSpeedMps + (secondLegMeters / 1000) * stopPenaltyPerKmSeconds

            let detected = Detected(
                intermediate: transferStation,
                finalAlighting: nearestOnOther,
                nextLine: otherLine,
                transferWalkSeconds: defaultTransferWalkSeconds,
                nextInVehicleSeconds: secondLegSeconds
            )
            if best == nil || saving > best!.saving {
                best = (saving, detected)
            }
        }
        return best?.detected
    }

    /// True when the snapshot has any evidence the line is running: at least
    /// one fresh arrival on the line, AND no major outage alert. When the
    /// snapshot has never been fetched we trust nothing and return false.
    public func isLineServiceViable(_ line: LineColor, snapshot: TransitSnapshot, now: Date = .now) -> Bool {
        let hasMajorAlert = snapshot.activeAlerts.contains { alert in
            alert.isActive(at: now)
                && alert.impactedLineColors.contains(line)
                && (alert.isMajor || alert.severity == .high)
        }
        if hasMajorAlert { return false }

        // If we've never fetched, we have no evidence either way — be
        // conservative and treat as not viable.
        guard let fetchedAt = snapshot.trainsFetchedAt else { return false }
        _ = fetchedAt

        let cutoff = now.addingTimeInterval(-recentArrivalWindowSeconds)
        let lineArrivals = snapshot.trainArrivals.filter {
            $0.line == line && !$0.isFault && $0.arrivalAt > cutoff
        }
        return !lineArrivals.isEmpty
    }

    private func isStationBetween(home: (lat: Double, lon: Double), work: (lat: Double, lon: Double), station: LStation) -> Bool {
        let homeToWork = haversineMeters(from: home, to: work)
        let homeToStation = haversineMeters(from: home, to: (station.latitude, station.longitude))
        let stationToWork = haversineMeters(from: (station.latitude, station.longitude), to: work)
        return homeToStation + stationToWork < homeToWork * pathDeviationTolerance
    }
}

func haversineMeters(from origin: (lat: Double, lon: Double), to dest: (lat: Double, lon: Double)) -> Double {
    let R: Double = 6_371_000
    let lat1 = origin.lat * .pi / 180
    let lat2 = dest.lat * .pi / 180
    let dLat = (dest.lat - origin.lat) * .pi / 180
    let dLon = (dest.lon - origin.lon) * .pi / 180
    let a = sin(dLat / 2) * sin(dLat / 2)
        + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * R * atan2(sqrt(a), sqrt(1 - a))
}
