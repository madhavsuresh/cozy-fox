import Foundation
import os
import TransitCache
import TransitDomain
import TransitModels

/// One-line-per-refresh-tick diagnostic log for the bus reliability
/// pipeline. Wired into `AppViewModel.loadCachedSnapshot()` so it runs
/// once per cycle after all the upstream state has settled.
///
/// **How to read these logs.** Connect the phone to a Mac, open
/// `Console.app`, select the device, and filter:
///
///     SUBSYSTEM contains[c] "net.thoughtbison.cozyfox"
///     CATEGORY contains[c] "BusReliability"
///
/// `info` lines give a one-line summary per cycle (good for streaming
/// while you test). `debug` lines drop down to per-prediction detail —
/// you may have to enable debug-level streaming in Console
/// (Action → "Include Debug Messages").
///
/// On the command line:
///
///     log stream --predicate 'subsystem == "net.thoughtbison.cozyfox"' --info --debug
///
/// or, for a past window:
///
///     log show --predicate 'subsystem == "net.thoughtbison.cozyfox"' \
///         --info --debug --last 30m
@MainActor
enum BusReliabilityDebugLogger {
    static let subsystem = "net.thoughtbison.cozyfox"
    static let logger = Logger(subsystem: subsystem, category: "BusReliability")

    static func log(
        snapshot: TransitSnapshot,
        vehiclePositions: [VehiclePosition],
        busVehicleHistory: [String: [BusVehicleHistorySample]],
        scorer: BusReliabilityScorer = BusReliabilityScorer(),
        calendar: Calendar = .currentChicago,
        now: Date = .now
    ) {
        let preds = snapshot.busPredictions
        let busVehicles = vehiclePositions.filter { $0.mode == .bus }
        let reliabilities = scorer.catalogedAssessments(
            for: preds,
            vehicles: vehiclePositions,
            activeDetours: snapshot.busDetours,
            patterns: snapshot.busPatterns,
            stopDetourStates: snapshot.busStopDetourStates,
            now: now
        )

        // State histogram.
        var stateCounts: [BusArrivalReliability.State: Int] = [:]
        var reasonCounts: [String: Int] = [:]
        for (_, reliability) in reliabilities {
            stateCounts[reliability.state, default: 0] += 1
            for reason in reliability.reasonCodes {
                reasonCounts[reason.rawValue, default: 0] += 1
            }
        }
        let displayable = reliabilities.values.filter(\.isDisplayable).count
        let hidden = preds.count - displayable

        // Single-line summary at .info level. Everything is `.public` —
        // this app is single-user and we own the subsystem; redaction
        // would just make the log unreadable.
        logger.info("""
        cycle preds=\(preds.count, privacy: .public) \
        busVehicles=\(busVehicles.count, privacy: .public) \
        patterns=\(snapshot.busPatterns.count, privacy: .public) \
        detours=\(snapshot.busDetours.count, privacy: .public) \
        stopDetourStates=\(snapshot.busStopDetourStates.count, privacy: .public) \
        history=\(busVehicleHistory.count, privacy: .public) \
        bins=\(snapshot.busResidualBins.count, privacy: .public) \
        displayable=\(displayable, privacy: .public) \
        hidden=\(hidden, privacy: .public) \
        states=\(Self.describe(stateCounts), privacy: .public) \
        reasons=\(Self.describe(reasonCounts), privacy: .public)
        """)

        // Per-prediction breadcrumbs at .debug level. Useful when the
        // info-line summary shows a count but you want to know *which*
        // prediction got hidden. Enable via Console.app → Action →
        // "Include Debug Messages" (or stream with `--debug`).
        for pred in preds.sorted(by: { $0.arrivalAt < $1.arrivalAt }).prefix(8) {
            let r = reliabilities[pred.id]
            let etaMin = (pred.arrivalAt.timeIntervalSince(now) / 60).rounded()
            let matchedVehicle = busVehicles.first { $0.id == pred.vehicleId }
            let vehicleNote: String
            if let v = matchedVehicle {
                let age = Int(now.timeIntervalSince(v.observedAt))
                let pid = v.patternId.map(String.init) ?? "nil"
                let pdist = v.patternDistanceFeet.map { Int($0).description } ?? "nil"
                vehicleNote = "vid=\(v.id) age=\(age)s pid=\(pid) pdist=\(pdist)"
            } else {
                vehicleNote = "vid=\(pred.vehicleId) NOT_FOUND"
            }
            logger.debug("""
            pred id=\(pred.id, privacy: .public) \
            rt=\(pred.route, privacy: .public) \
            dir=\(pred.directionName, privacy: .public) \
            stop=\(pred.stopId, privacy: .public) \
            eta=\(etaMin, privacy: .public)m \
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

extension BusArrivalReliability.State: CustomStringConvertible {
    public var description: String { rawValue }
}
