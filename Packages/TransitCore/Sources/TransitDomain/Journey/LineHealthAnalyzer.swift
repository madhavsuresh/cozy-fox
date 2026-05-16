import Foundation
import TransitModels

public struct LineHealthAnalyzer: Sendable {
    public init() {}

    public func analyze(
        route: String,
        direction: String? = nil,
        upcomingArrivals: [Date],
        baselineHeadwaySeconds: TimeInterval?,
        feedState: FeedState,
        generatedAt: Date
    ) -> LineHealthSnapshot {
        if feedState == .missing {
            return snapshot(route, direction, state: .feedStale, confidence: 0.2, summary: "Feed missing.", generatedAt)
        }
        if feedState == .stale {
            return snapshot(route, direction, state: .feedStale, confidence: 0.35, summary: "Feed stale.", generatedAt)
        }
        let sorted = upcomingArrivals.sorted()
        guard sorted.count >= 2 else {
            return snapshot(route, direction, state: .insufficientData, confidence: 0.2, summary: nil, generatedAt)
        }

        var gaps: [TimeInterval] = []
        for i in 1..<sorted.count {
            gaps.append(sorted[i].timeIntervalSince(sorted[i - 1]))
        }

        let bunchingHint = HeadwayBunchingDetector().detect(arrivalTimes: sorted)
        let median = medianOf(gaps)
        let firstGap = gaps[0]

        if let baseline = baselineHeadwaySeconds, baseline > 0 {
            let ratio = median / baseline
            if firstGap > 1.8 * baseline {
                let mins = Int((firstGap / 60).rounded())
                return snapshot(
                    route, direction,
                    state: bunchingHint != nil ? .bunchedThenGap : .longGap,
                    confidence: 0.7,
                    summary: "Long gap (\(mins) min) on \(route).",
                    generatedAt
                )
            }
            if ratio < 0.6 {
                return snapshot(route, direction, state: .compressed, confidence: 0.55, summary: "Compressed headways.", generatedAt)
            }
            if ratio > 1.4 {
                return snapshot(route, direction, state: .degraded, confidence: 0.55, summary: "Headways elongated.", generatedAt)
            }
        } else if bunchingHint != nil {
            return snapshot(route, direction, state: .bunchedThenGap, confidence: 0.55, summary: "Bunched leading arrivals.", generatedAt)
        }

        if bunchingHint != nil {
            return snapshot(route, direction, state: .bunchedThenGap, confidence: 0.6, summary: "Bunched leading arrivals.", generatedAt)
        }

        return snapshot(route, direction, state: .normal, confidence: 0.7, summary: nil, generatedAt)
    }

    private func snapshot(
        _ route: String,
        _ direction: String?,
        state: LineHealthState,
        confidence: Double,
        summary: String?,
        _ generatedAt: Date
    ) -> LineHealthSnapshot {
        LineHealthSnapshot(
            route: route,
            direction: direction,
            state: state,
            confidence: confidence,
            generatedAt: generatedAt,
            summary: summary
        )
    }
}
