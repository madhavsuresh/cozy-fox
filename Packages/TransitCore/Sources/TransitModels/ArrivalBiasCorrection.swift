import Foundation

/// A user-facing correction to the headline arrival ETA, derived from a
/// confident `BiasCell`. Phase 3 surfaces this as a muted secondary line
/// (e.g. `usually +2m`) under the headline `BigNumber` in the train, bus
/// and Metra block views.
///
/// The factory `from(cell:)` is the only sanctioned way to construct one
/// — it enforces the confidence gates. Callers that get back `nil` must
/// render nothing additional (the dashboard either has signal worth
/// showing or it doesn't; there is no in-between state).
public struct ArrivalBiasCorrection: Sendable, Hashable {
    /// Which way the bias points. `apiEarly` means the prediction tends
    /// to arrive *before* the vehicle does — the user should add minutes
    /// to the displayed ETA. `apiLate` is the inverse.
    public enum Direction: Sendable, Hashable {
        /// Vehicle arrives **later** than the API predicted — API runs early.
        case apiEarly
        /// Vehicle arrives **earlier** than the API predicted — API runs late.
        case apiLate
    }

    public let direction: Direction

    /// Magnitude of the bias in seconds. Always positive — the sign is
    /// carried by `direction`. We use a mean (Welford) under the hood but
    /// expose magnitude so the property name doesn't lie when the
    /// distribution is skewed.
    public let magnitudeSeconds: Double

    /// Sample standard deviation of the underlying cell, in seconds.
    /// Optional because cells with `count < 2` have undefined variance.
    /// Surfaced (when it rounds to ≥1 minute) as a `±Nm` annotation so
    /// users see *how reliable* the bias estimate itself is, not just
    /// its central tendency.
    public let stdDevSeconds: Double?

    public init(
        direction: Direction,
        magnitudeSeconds: Double,
        stdDevSeconds: Double? = nil
    ) {
        self.direction = direction
        self.magnitudeSeconds = magnitudeSeconds
        self.stdDevSeconds = stdDevSeconds
    }

    /// The magnitude rounded to whole minutes. Used for display.
    /// The confidence gate in `from(cell:)` requires
    /// `abs(mean) >= 90s`, so in practice `minutes` is always `>= 2`;
    /// `0` is only reachable if a caller constructs the value directly.
    public var minutes: Int {
        Int((magnitudeSeconds / 60).rounded())
    }

    /// Standard deviation rounded to whole minutes. Returns `nil` when
    /// no stddev is available or when it rounds to zero — small
    /// uncertainties don't earn pixels.
    public var stdDevMinutes: Int? {
        guard let stdDevSeconds, stdDevSeconds >= 30 else { return nil }
        return Int((stdDevSeconds / 60).rounded())
    }

    /// e.g. `"usually +2m ±1m"` when the stddev rounds to ≥ 1 minute,
    /// else just `"usually +2m"`. The minus sign is a real minus (U+2212),
    /// not an ASCII hyphen, so it lines up cleanly with the plus glyph at
    /// small type sizes. The `m` suffix matches the rest of the
    /// dashboard's terse minute formatting (`BigNumber` uses `min`
    /// separately as a unit label; this is more compact because it rides
    /// next to a number that already says "minutes" in context).
    public var displayText: String {
        let prefix: String
        switch direction {
        case .apiEarly: prefix = "+"
        case .apiLate:  prefix = "\u{2212}" // U+2212 MINUS SIGN
        }
        var base = "usually \(prefix)\(minutes)m"
        if let stdMinutes = stdDevMinutes, stdMinutes > 0 {
            base += " ±\(stdMinutes)m"
        }
        return base
    }

    /// Spelled-out form for VoiceOver. Reads naturally and never
    /// pluralises "1 minute". When uncertainty is surfacable, it gets
    /// folded into the sentence so VoiceOver users hear it too.
    public var accessibilityLabel: String {
        let mins = minutes
        let unit = mins == 1 ? "minute" : "minutes"
        let direction: String
        switch self.direction {
        case .apiEarly: direction = "Usually \(mins) \(unit) later than predicted"
        case .apiLate:  direction = "Usually \(mins) \(unit) earlier than predicted"
        }
        if let stdMinutes = stdDevMinutes, stdMinutes > 0 {
            let stdUnit = stdMinutes == 1 ? "minute" : "minutes"
            return "\(direction), give or take \(stdMinutes) \(stdUnit)"
        }
        return direction
    }

    // MARK: - Factory

    /// Build a correction from a `BiasCell`. Returns `nil` when the cell
    /// fails any of the three confidence gates:
    ///
    /// 1. `count >= minSampleCount` — at least this many resolved samples
    /// 2. `abs(mean) >= minAbsMeanSeconds` — large enough to be worth surfacing
    /// 3. `abs(mean) > confidenceFactor * stderr` — deterministic proxy
    ///    for "bootstrap CI excludes zero" without actually bootstrapping.
    ///    `stderr = stddev / sqrt(count)`; falls back to `nil` (gate fails)
    ///    when `cell.standardDeviation` is `nil` (count < 2) or zero.
    ///
    /// Sign convention follows `BiasCell.mean`: positive ⇒ `apiEarly`
    /// (vehicle later than predicted), negative ⇒ `apiLate`.
    public static func from(
        cell: BiasCell?,
        minSampleCount: Int = 12,
        minAbsMeanSeconds: Double = 90,
        confidenceFactor: Double = 1.5
    ) -> ArrivalBiasCorrection? {
        guard let cell, cell.count >= minSampleCount else { return nil }
        guard abs(cell.mean) >= minAbsMeanSeconds else { return nil }
        guard let stddev = cell.standardDeviation, stddev > 0 else { return nil }
        let standardError = stddev / Double(cell.count).squareRoot()
        guard abs(cell.mean) > confidenceFactor * standardError else { return nil }
        let direction: Direction = cell.mean > 0 ? .apiEarly : .apiLate
        return ArrivalBiasCorrection(
            direction: direction,
            magnitudeSeconds: abs(cell.mean),
            stdDevSeconds: stddev
        )
    }
}
