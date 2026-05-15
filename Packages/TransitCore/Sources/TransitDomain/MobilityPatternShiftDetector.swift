import Foundation
import TransitModels

/// Pure detector that scores how much the user's *recent* mobility
/// differs from their *long-term* pattern. Output is a 0.0–1.0 score:
/// - **0.0**: every recent route observation is one of the user's top
///   long-term routes — patterns are stable.
/// - **1.0**: zero recent observations match any top-K long-term route
///   — patterns have shifted completely.
///
/// Substrate, no consumer yet. Future uses include gating
/// `LocalPredictionEngine`'s summary-based predictions when patterns
/// have shifted (don't over-trust the long-term model), or surfacing a
/// "Cozy Fox is re-learning" hint in Phase 2.5's Live Activity.
///
/// Algorithm: take the top-K most-frequent `(mode, routeId)` patterns
/// from `MobilityProfileSummary`. Count how many recent (last
/// `recentWindowDays`) route observations match one of those keys.
/// Score = 1 − (matches ÷ total recent). Symmetric across modes —
/// switching from bus to a different bus is the same kind of shift as
/// switching from bus to train.
///
/// Edge cases handled explicitly:
/// - No recent observations → score 0 (we have no signal, default to
///   "stable" rather than alarming).
/// - No long-term summary patterns → score 0 (new user; "everything
///   is novel" doesn't help anyone).
/// - Recent observation with no mode/route fields (a manual context
///   tap that didn't pin a route) → ignored, doesn't count toward
///   total or matches.
public struct MobilityPatternShiftDetector: Sendable {
    public init() {}

    public func shiftScore(
        profile: MobilityProfile,
        recentWindowDays: Int = 7,
        topK: Int = 5,
        now: Date = .now
    ) -> Double {
        let cutoff = now.addingTimeInterval(-Double(recentWindowDays) * 86_400)
        let recent = profile.routeObservations.filter { $0.recordedAt >= cutoff }
        guard !recent.isEmpty else { return 0.0 }

        let topPatterns = profile.summary.routePatterns.values
            .sorted { $0.totalCount > $1.totalCount }
            .prefix(topK)
        guard !topPatterns.isEmpty else { return 0.0 }

        let topKeys: Set<String> = Set(topPatterns.map { Self.key(mode: $0.mode, routeId: $0.routeId) })

        var classified = 0
        var matches = 0
        for observation in recent {
            guard let observationKey = Self.key(observation: observation) else { continue }
            classified += 1
            if topKeys.contains(observationKey) {
                matches += 1
            }
        }
        guard classified > 0 else { return 0.0 }
        return 1.0 - Double(matches) / Double(classified)
    }

    private static func key(
        mode: MobilityProfileSummary.RoutePattern.Mode,
        routeId: String
    ) -> String {
        "\(mode.rawValue):\(routeId)"
    }

    private static func key(observation: MobilityProfile.RouteObservation) -> String? {
        if let line = observation.line {
            return key(mode: .train, routeId: line.rawValue)
        }
        if let bus = observation.busRoute {
            return key(mode: .bus, routeId: bus)
        }
        if let metra = observation.metraRoute {
            return key(mode: .metra, routeId: metra)
        }
        return nil
    }
}
