import Foundation

/// Pure detector for "is the headline arrival bunched with the next
/// one?" — i.e., are the first two upcoming arrivals so close together
/// in time that they're effectively a pair, with a long gap before the
/// third one?
///
/// This is **not** a prediction. It's an observation about the current
/// API snapshot's internal consistency. When the agency reports
/// `[8 min, 11 min, 22 min, 32 min]`, the first two are bunched —
/// they're 3 minutes apart while subsequent gaps are 10 minutes apart.
/// A rider who narrowly misses the first one only waits 3 more minutes
/// for the next; a rider who arrives early shouldn't sprint, because
/// there's a "+ another in 3m" right behind it.
///
/// The detector is mode-agnostic: it takes a list of `Date`s and
/// returns the gap to the next arrival (in seconds) iff that gap is
/// notably smaller than the gaps further down the snapshot.
///
/// Gates (defaults):
/// - Need at least 4 arrivals so we have ≥2 comparison gaps after the
///   one we're testing. With fewer, the "is this bunched" question is
///   too noisy to answer.
/// - First-gap must be < `bunchingRatio * median(subsequent gaps)`.
///   Default 0.5 — a 4-min gap is bunched against an 8-min typical
///   headway, but not against a 7-min one.
/// - First-gap must also be ≤ `absoluteFloorSeconds` (default 4 min).
///   "Bunched but next is 6 min away" isn't urgent enough to surface.
public struct HeadwayBunchingDetector: Sendable {
    public struct Hint: Sendable, Hashable {
        /// Seconds from the headline arrival to the next one. Always
        /// positive; the caller formats it for display.
        public let nextArrivalAfterSeconds: TimeInterval

        public init(nextArrivalAfterSeconds: TimeInterval) {
            self.nextArrivalAfterSeconds = nextArrivalAfterSeconds
        }

        /// Rounded to whole minutes for the surface text. Always >= 1
        /// because the absolute-floor gate keeps us above that.
        public var minutes: Int {
            max(1, Int((nextArrivalAfterSeconds / 60).rounded()))
        }
    }

    public init() {}

    public func detect(
        arrivalTimes: [Date],
        bunchingRatio: Double = 0.5,
        absoluteFloorSeconds: TimeInterval = 4 * 60,
        minimumArrivals: Int = 4
    ) -> Hint? {
        let sorted = arrivalTimes.sorted()
        guard sorted.count >= minimumArrivals else { return nil }

        let gaps = stride(from: 1, to: sorted.count, by: 1).map {
            sorted[$0].timeIntervalSince(sorted[$0 - 1])
        }
        // Need at least one subsequent gap to compute a comparison
        // median. `minimumArrivals` defaults to 4 so this always
        // succeeds in production; callers can relax to 3 when they
        // accept a 1-sample median.
        guard gaps.count >= 2 else { return nil }

        let firstGap = gaps[0]
        guard firstGap > 0 else { return nil }
        guard firstGap <= absoluteFloorSeconds else { return nil }

        let subsequent = Array(gaps.dropFirst())
        let medianSubsequent = median(of: subsequent)
        guard medianSubsequent > 0 else { return nil }
        guard firstGap < bunchingRatio * medianSubsequent else { return nil }

        return Hint(nextArrivalAfterSeconds: firstGap)
    }

    /// Median of a non-empty array. For even-length input, picks the
    /// average of the two middle values; matches the textbook
    /// definition so tests are easy to write deterministically.
    private func median(of values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
}
