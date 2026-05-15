import Foundation
import TransitModels

/// Phase 6 substrate: an empirical next-context predictor trained from a
/// `MobilityProfile`'s rolling observation stream.
///
/// Conceptually a learned conditional probability over `CommuteContext`
/// transitions, keyed on `(currentContext, hourOfWeek)`. The "model" is
/// a transition-count histogram with per-bucket normalization at
/// prediction time. No Core ML, no external framework — works with the
/// limited data new users produce in their first few days and scales
/// linearly with observation count.
///
/// Returns `AnchorID`-flavored predictions (`.home`, `.work`, or a
/// synthetic `.bucketed(0, 0)` for `.elsewhere`) so consumers that key
/// off `AnchorID` (`CommuteAutopinner`, future LSTM replacement) can
/// drop this in. `.unknown` observations are filtered out of training —
/// they're not actionable.
///
/// Future Phase 6: when ≥6 weeks of `MobilityProfileSummary` accumulate
/// and offline-trained Core ML weights ship in the app bundle, the
/// `predict` API can be swapped for an LSTM that consumes the same
/// `(currentContext, hourOfWeek)` features. Tests pin the contract, not
/// the implementation.
public struct NextContextPredictor: Sendable {
    /// One predicted future context, with confidence + sample evidence.
    public struct Prediction: Sendable, Hashable {
        public let context: CommuteContext
        public let anchor: AnchorID
        public let probability: Double
        public let sampleCount: Int

        public init(
            context: CommuteContext,
            anchor: AnchorID,
            probability: Double,
            sampleCount: Int
        ) {
            self.context = context
            self.anchor = anchor
            self.probability = probability
            self.sampleCount = sampleCount
        }
    }

    /// Key into the transition histogram.
    public struct FeatureKey: Hashable, Sendable {
        public let currentContext: CommuteContext
        public let hourOfWeek: Int

        public init(currentContext: CommuteContext, hourOfWeek: Int) {
            self.currentContext = currentContext
            self.hourOfWeek = hourOfWeek
        }
    }

    /// `[FeatureKey: [nextContext: count]]`. Exposed so consumers can
    /// snapshot the model for diagnostics or persist it.
    public let transitions: [FeatureKey: [CommuteContext: Int]]

    public init(transitions: [FeatureKey: [CommuteContext: Int]]) {
        self.transitions = transitions
    }

    /// Build a trained predictor from a profile's observation stream.
    ///
    /// Sorts observations by `recordedAt`, then pairs each with its
    /// successor as a training tuple `(currentContext, hourOfWeek) →
    /// nextContext`. Observations whose context is `.unknown` are
    /// skipped on both sides of the pair — they don't carry actionable
    /// signal. Persistence-pairs (same context as successor) ARE kept;
    /// they encode "at 3am you stay home," which is predictive.
    public static func train(
        from observations: [MobilityProfile.Observation]
    ) -> Self {
        let sorted = observations.sorted { $0.recordedAt < $1.recordedAt }
        var transitions: [FeatureKey: [CommuteContext: Int]] = [:]

        for index in sorted.indices.dropLast() {
            let current = sorted[index]
            let next = sorted[index + 1]
            guard current.context != .unknown, next.context != .unknown else { continue }
            let hourOfWeek = HourOfWeek.index(weekday: current.weekday, hour: current.hour)
            let key = FeatureKey(currentContext: current.context, hourOfWeek: hourOfWeek)
            transitions[key, default: [:]][next.context, default: 0] += 1
        }

        return NextContextPredictor(transitions: transitions)
    }

    /// Top-K most-likely next contexts given the current state. Sorted
    /// by probability descending, ties broken by sample count (more
    /// observations wins).
    ///
    /// Returns an empty array when the (currentContext, hourOfWeek)
    /// bucket has fewer than `minSamples` total observations. The gate
    /// keeps a single anomalous observation from producing a 100%-
    /// confident prediction.
    public func predict(
        currentContext: CommuteContext,
        hourOfWeek: Int,
        topK: Int = 3,
        minSamples: Int = 5
    ) -> [Prediction] {
        let key = FeatureKey(currentContext: currentContext, hourOfWeek: hourOfWeek)
        guard let counts = transitions[key] else { return [] }
        let total = counts.values.reduce(0, +)
        guard total >= minSamples else { return [] }
        let totalDouble = Double(total)

        let ranked = counts
            .map { (context, count) -> Prediction in
                Prediction(
                    context: context,
                    anchor: Self.anchor(for: context),
                    probability: Double(count) / totalDouble,
                    sampleCount: count
                )
            }
            .sorted { lhs, rhs in
                if lhs.probability != rhs.probability {
                    return lhs.probability > rhs.probability
                }
                return lhs.sampleCount > rhs.sampleCount
            }
            .prefix(topK)
        return Array(ranked)
    }

    /// Diagnostics: total number of training tuples consumed.
    public var trainingSampleCount: Int {
        transitions.values.reduce(0) { acc, counts in
            acc + counts.values.reduce(0, +)
        }
    }

    /// Test hook.
    public var bucketCountForTests: Int { transitions.count }

    /// Map a `CommuteContext` to its `AnchorID` equivalent. `.home` and
    /// `.work` are semantic anchors; `.elsewhere` is intentionally a
    /// degenerate `.bucketed(0, 0)` synthetic — callers should treat it
    /// as "somewhere not-home-not-work" and route accordingly. `.unknown`
    /// never reaches here (filtered in training + predict).
    private static func anchor(for context: CommuteContext) -> AnchorID {
        switch context {
        case .atHome: return .home
        case .atWork: return .work
        case .elsewhere, .unknown:
            return .bucketed(latCell: 0, lonCell: 0)
        }
    }
}
