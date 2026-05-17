import Foundation
import os
import TransitCache
import TransitDomain
import TransitModels

/// One-line-per-refresh-tick diagnostic log for the train reliability
/// pipeline. Mirror of `BusReliabilityDebugLogger`.
///
/// **How to read these logs.** Connect the phone to a Mac, open
/// `Console.app`, select the device, and filter:
///
///     SUBSYSTEM contains[c] "net.thoughtbison.cozyfox"
///     CATEGORY contains[c] "TrainReliability"
///
/// On the command line:
///
///     log stream --predicate 'subsystem == "net.thoughtbison.cozyfox" && category == "TrainReliability"' --info --debug
///
@MainActor
enum TrainReliabilityDebugLogger {
    static let subsystem = "net.thoughtbison.cozyfox"
    static let logger = Logger(subsystem: subsystem, category: "TrainReliability")

    static func log(
        snapshot: TransitSnapshot,
        vehiclePositions: [VehiclePosition],
        scorer: TrainReliabilityScorer = TrainReliabilityScorer(),
        now: Date = .now
    ) {
        let arrivals = snapshot.trainArrivals
        let trainVehicles = vehiclePositions.filter { $0.mode == .train }
        let reliabilities = scorer.catalogedAssessments(
            for: arrivals,
            vehiclePositions: vehiclePositions,
            alerts: snapshot.activeAlerts,
            now: now
        )

        var stateCounts: [TrainArrivalReliability.State: Int] = [:]
        var reasonCounts: [String: Int] = [:]
        for (_, reliability) in reliabilities {
            stateCounts[reliability.state, default: 0] += 1
            for reason in reliability.reasonCodes {
                reasonCounts[reason.rawValue, default: 0] += 1
            }
        }
        let displayable = reliabilities.values.filter(\.isDisplayable).count
        let hidden = arrivals.count - displayable

        logger.info("""
        cycle arrivals=\(arrivals.count, privacy: .public) \
        trainVehicles=\(trainVehicles.count, privacy: .public) \
        alerts=\(snapshot.activeAlerts.count, privacy: .public) \
        displayable=\(displayable, privacy: .public) \
        hidden=\(hidden, privacy: .public) \
        states=\(Self.describe(stateCounts), privacy: .public) \
        reasons=\(Self.describe(reasonCounts), privacy: .public)
        """)

        for arrival in arrivals.sorted(by: { $0.arrivalAt < $1.arrivalAt }).prefix(8) {
            let r = reliabilities[arrival.id]
            let etaMin = (arrival.arrivalAt.timeIntervalSince(now) / 60).rounded()
            let runKey = arrival.runNumber.lowercased()
            let matchedVehicle = trainVehicles.first { $0.id.lowercased() == runKey }
            let vehicleNote: String
            if let v = matchedVehicle {
                let age = Int(now.timeIntervalSince(v.observedAt))
                let next = v.nextStopId.map(String.init) ?? "nil"
                vehicleNote = "run=\(v.id) age=\(age)s nextStop=\(next)"
            } else {
                vehicleNote = "run=\(arrival.runNumber) NOT_FOUND"
            }
            logger.debug("""
            arr id=\(arrival.id, privacy: .public) \
            line=\(arrival.line.rawValue, privacy: .public) \
            station=\(arrival.stationId, privacy: .public) \
            stop=\(arrival.stopId, privacy: .public) \
            eta=\(etaMin, privacy: .public)m \
            isApp=\(arrival.isApproaching, privacy: .public) \
            isSch=\(arrival.isScheduled, privacy: .public) \
            isFlt=\(arrival.isFault, privacy: .public) \
            isDly=\(arrival.isDelayed, privacy: .public) \
            \(vehicleNote, privacy: .public) \
            state=\(r?.state.rawValue ?? "unscored", privacy: .public) \
            score=\(r?.score ?? 0, privacy: .public) \
            reasons=\(r?.reasonCodes.map(\.rawValue).joined(separator: ",") ?? "", privacy: .public)
            """)
        }
    }

    private static func describe<K: Hashable & CustomStringConvertible>(
        _ counts: [K: Int]
    ) -> String {
        guard !counts.isEmpty else { return "{}" }
        let items = counts
            .sorted { $0.key.description < $1.key.description }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return "{\(items)}"
    }
}

extension TrainArrivalReliability.State: CustomStringConvertible {
    public var description: String { rawValue }
}
