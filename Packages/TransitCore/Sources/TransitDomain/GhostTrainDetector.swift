import Foundation
import TransitModels

public struct GhostTrainAssessment: Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case live
        case scheduledOnly
        case unconfirmed
        case likelyGhost
        case staleFeed
    }

    public let id: String
    public let arrivalId: String
    public let status: Status
    /// 0 means no ghost risk; 1 means the arrival is very likely not backed by
    /// a live train.
    public let ghostScore: Double
    public let reason: String
    public let matchingVehicleId: String?

    public init(
        arrivalId: String,
        status: Status,
        ghostScore: Double,
        reason: String,
        matchingVehicleId: String? = nil
    ) {
        self.id = arrivalId
        self.arrivalId = arrivalId
        self.status = status
        self.ghostScore = min(max(ghostScore, 0), 1)
        self.reason = reason
        self.matchingVehicleId = matchingVehicleId
    }

    public var isGhostLikely: Bool {
        status == .likelyGhost
    }

    public var needsRiderAttention: Bool {
        switch status {
        case .unconfirmed, .likelyGhost, .staleFeed:
            true
        case .live, .scheduledOnly:
            false
        }
    }
}

public struct GhostTrainDetector: Sendable {
    public var realtimeFreshness: TimeInterval
    public var vehicleFreshness: TimeInterval
    public var feedStaleAfter: TimeInterval
    public var unconfirmedWindow: TimeInterval
    public var ghostWindow: TimeInterval
    public var pastDueGrace: TimeInterval

    public init(
        realtimeFreshness: TimeInterval = 3 * 60,
        vehicleFreshness: TimeInterval = 3 * 60,
        feedStaleAfter: TimeInterval = 6 * 60,
        unconfirmedWindow: TimeInterval = 10 * 60,
        ghostWindow: TimeInterval = 2 * 60,
        pastDueGrace: TimeInterval = 60
    ) {
        self.realtimeFreshness = realtimeFreshness
        self.vehicleFreshness = vehicleFreshness
        self.feedStaleAfter = feedStaleAfter
        self.unconfirmedWindow = unconfirmedWindow
        self.ghostWindow = ghostWindow
        self.pastDueGrace = pastDueGrace
    }

    public func assessments(
        for arrivals: [Arrival],
        vehiclePositions: [VehiclePosition],
        arrivalsFetchedAt: Date? = nil,
        now: Date = .now
    ) -> [String: GhostTrainAssessment] {
        Dictionary(uniqueKeysWithValues: arrivals.map { arrival in
            (
                arrival.id,
                assessment(
                    for: arrival,
                    vehiclePositions: vehiclePositions,
                    arrivalsFetchedAt: arrivalsFetchedAt,
                    now: now
                )
            )
        })
    }

    public func assessment(
        for arrival: Arrival,
        vehiclePositions: [VehiclePosition],
        arrivalsFetchedAt: Date? = nil,
        now: Date = .now
    ) -> GhostTrainAssessment {
        let routePositions = freshTrainPositions(
            matching: arrival.line,
            in: vehiclePositions,
            now: now
        )
        if let exact = exactVehicle(for: arrival, in: routePositions) {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .live,
                ghostScore: 0,
                reason: "Live run \(exact.id) is reporting a vehicle position.",
                matchingVehicleId: exact.id
            )
        }

        let predictionAge = predictionAge(for: arrival, now: now)
        let cacheAge = arrivalsFetchedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        let etaIsFresh = predictionAge <= realtimeFreshness
        let feedLooksStale = (predictionAge > feedStaleAfter || cacheAge > feedStaleAfter)
            && routePositions.isEmpty
        let secondsUntilArrival = arrival.arrivalAt.timeIntervalSince(now)

        if feedLooksStale {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .staleFeed,
                ghostScore: 0.25,
                reason: "The train feed is stale, so this arrival cannot be verified."
            )
        }

        if arrival.isFault {
            return unresolvedAssessment(
                for: arrival,
                secondsUntilArrival: secondsUntilArrival,
                baseScore: 0.74,
                reason: "CTA marked this prediction as faulty and no matching live run was found."
            )
        }

        if !arrival.isScheduled && etaIsFresh {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .live,
                ghostScore: routePositions.isEmpty ? 0.18 : 0.08,
                reason: "CTA is publishing a fresh realtime prediction for this run."
            )
        }

        if arrival.isScheduled || !etaIsFresh {
            let baseScore = arrival.isScheduled ? 0.62 : 0.52
            let reason = arrival.isScheduled
                ? "CTA is showing a schedule-only arrival and no matching live run was found."
                : "The prediction has not refreshed recently and no matching live run was found."
            return unresolvedAssessment(
                for: arrival,
                secondsUntilArrival: secondsUntilArrival,
                baseScore: baseScore,
                reason: reason
            )
        }

        return unresolvedAssessment(
            for: arrival,
            secondsUntilArrival: secondsUntilArrival,
            baseScore: 0.45,
            reason: "No matching live run was found for this arrival yet."
        )
    }

    private func freshTrainPositions(
        matching line: LineColor,
        in positions: [VehiclePosition],
        now: Date
    ) -> [VehiclePosition] {
        positions.filter {
            $0.mode == .train
                && $0.route == line.rawValue
                && now.timeIntervalSince($0.observedAt) <= vehicleFreshness
        }
    }

    private func exactVehicle(
        for arrival: Arrival,
        in positions: [VehiclePosition]
    ) -> VehiclePosition? {
        let runNumber = normalizedIdentifier(arrival.runNumber)
        return positions.first {
            normalizedIdentifier($0.id) == runNumber
        }
    }

    private func predictionAge(
        for arrival: Arrival,
        now: Date
    ) -> TimeInterval {
        max(0, now.timeIntervalSince(arrival.predictedAt))
    }

    private func unresolvedAssessment(
        for arrival: Arrival,
        secondsUntilArrival: TimeInterval,
        baseScore: Double,
        reason: String
    ) -> GhostTrainAssessment {
        if secondsUntilArrival < -pastDueGrace {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .likelyGhost,
                ghostScore: max(baseScore, 0.9),
                reason: "\(reason) The listed arrival time has already passed."
            )
        }

        if secondsUntilArrival <= ghostWindow {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .likelyGhost,
                ghostScore: max(baseScore, 0.78),
                reason: "\(reason) It is due imminently."
            )
        }

        if secondsUntilArrival <= unconfirmedWindow {
            return GhostTrainAssessment(
                arrivalId: arrival.id,
                status: .unconfirmed,
                ghostScore: max(baseScore, 0.55),
                reason: reason
            )
        }

        return GhostTrainAssessment(
            arrivalId: arrival.id,
            status: .scheduledOnly,
            ghostScore: max(baseScore, 0.35),
            reason: reason
        )
    }

    private func normalizedIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
