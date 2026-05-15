import ActivityKit
import ChicagoTheme
import SwiftUI
import TransitModels
import TransitUI
import WidgetKit

// MARK: - Palette
//
// Live Activities don't reliably inherit the device's colorScheme — iOS
// often renders them in a "dark" internal context regardless of
// `activityBackgroundTint`, which is what produced white-on-white text
// in earlier builds. We use a fixed dark chrome plus only the
// dark-safe Chicago palette (`OnDarkSafe`) so every accent we choose
// has ≥4.5:1 contrast against near-black. Bahama / Lochmara are
// intentionally absent — they disappear against the lock-screen
// background.

private let activityBackground = Color(red: 0.10, green: 0.10, blue: 0.12)

// Live Activity content is pushed on a background-refresh cadence, so the
// `nextArrival` Date captured at update time will routinely age into the
// past between pushes. `Text(_, style: .relative)` keeps ticking past
// the target — it'll happily count up after zero — and `HeadwayDotStrip`
// filters past entries (`delta >= 0`) — so the big number and the dot
// strip can disagree. We re-derive the countdown from `upcomingArrivals`
// against `TimelineView`'s `context.date` so the view body re-evaluates
// at each arrival's moment and swaps the live-ticking `Text` over to
// the next future arrival instead of counting up past zero.
private enum Countdown {
    case future(Date)
    case none

    var futureDate: Date? {
        if case .future(let date) = self { return date }
        return nil
    }
}

private extension Array where Element == Date {
    func firstFuture(now: Date, fallback: Date?) -> Countdown {
        if let next = first(where: { $0 > now }) {
            return .future(next)
        }
        if let fallback, fallback > now {
            return .future(fallback)
        }
        return .none
    }
}

@ViewBuilder
private func countdownView(_ countdown: Countdown) -> some View {
    switch countdown {
    case .future(let date):
        Text(date, style: .relative)
    case .none:
        Text(verbatim: "—")
    }
}

// Dates at which we want the view body to re-evaluate so the countdown
// can swap to the next future arrival instead of letting `Text(_,
// style: .relative)` tick past zero. `upcomingArrivals` is the rich
// list; `fallbackNext` covers older saved state. Sorted ascending,
// duplicates removed — SwiftUI requires explicit schedules in
// chronological order.
private func timelineEntries(upcoming: [Date], fallback: Date) -> [Date] {
    let now = Date.now
    let combined = (upcoming.isEmpty ? [fallback] : upcoming) + [fallback]
    return Array(Set(combined.filter { $0 > now })).sorted()
}

struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(activityBackground)
                .activitySystemActionForegroundColor(ChicagoPalette.OnDarkSafe.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    expandedBottom(state: context.state)
                }
            } compactLeading: {
                compactMarks(state: context.state)
            } compactTrailing: {
                TimelineView(.explicit(compactTimelineEntries(state: context.state))) { timeline in
                    countdownView(
                        soonestCountdown(state: context.state, now: timeline.date)
                    )
                    .font(ChicagoTypography.bigNumber(13, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                }
            } minimal: {
                compactMarks(state: context.state)
            }
        }
    }

    // MARK: - Expanded Dynamic Island regions

    @ViewBuilder
    private func expandedLeading(state: CommuteAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            if let train = state.train {
                trainLegRow(train)
            }
            if let bus = state.bus {
                busLegRow(bus)
            }
        }
    }

    @ViewBuilder
    private func expandedTrailing(state: CommuteAttributes.ContentState) -> some View {
        VStack(alignment: .trailing, spacing: ChicagoSpacing.xs) {
            if let train = state.train {
                arrivalStack(
                    upcoming: train.upcomingArrivals,
                    fallbackNext: train.nextArrival,
                    fallbackFollowing: train.followingArrival
                )
            }
            if let bus = state.bus {
                arrivalStack(
                    upcoming: bus.upcomingArrivals,
                    fallbackNext: bus.nextArrival,
                    fallbackFollowing: bus.followingArrival
                )
            }
        }
    }

    @ViewBuilder
    private func expandedBottom(state: CommuteAttributes.ContentState) -> some View {
        let alerts = [state.train?.alertHeadline, state.bus?.alertHeadline]
            .compactMap { $0 }
        if let first = alerts.first {
            Label(first, systemImage: "exclamationmark.triangle.fill")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.OnDarkSafe.starRed)
                .lineLimit(2)
        }
    }

    private func compactMarks(state: CommuteAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            if let train = state.train, let line = LineColor(rawValue: train.lineColorRaw) {
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
                    .fill(line.swiftUIColor)
                    .frame(width: 10, height: 12)
            }
            if state.bus != nil {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.gold)
            }
        }
    }

    // MARK: - Leg rows

    private func trainLegRow(_ leg: CommuteAttributes.TrainLeg) -> some View {
        let line = LineColor(rawValue: leg.lineColorRaw) ?? .red
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(line: line, size: .sm)
                Text("→ \(leg.destination)")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                    .lineLimit(1)
            }
            Text(leg.stopName)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.OnDarkSafe.secondary)
                .lineLimit(1)
        }
    }

    private func busLegRow(_ leg: CommuteAttributes.BusLeg) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(bus: leg.routeLabel, size: .sm)
                Text("→ \(leg.destination)")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                    .lineLimit(1)
            }
            Text(leg.stopName)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.OnDarkSafe.secondary)
                .lineLimit(1)
        }
    }

    private func arrivalStack(
        upcoming: [Date],
        fallbackNext: Date,
        fallbackFollowing: Date?
    ) -> some View {
        let entries = timelineEntries(upcoming: upcoming, fallback: fallbackNext)
        return TimelineView(.explicit(entries)) { timeline in
            let primary = upcoming.firstFuture(now: timeline.date, fallback: fallbackNext)
            let secondary = secondaryFutureArrival(
                upcoming: upcoming,
                now: timeline.date,
                fallback: fallbackFollowing
            )
            VStack(alignment: .trailing, spacing: 0) {
                countdownView(primary)
                    .font(ChicagoTypography.bigNumber(18, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                if let secondary {
                    Text(secondary, style: .relative)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .monospacedDigit()
                        .foregroundStyle(ChicagoPalette.OnDarkSafe.tertiary)
                }
            }
        }
    }

    private func soonestCountdown(
        state: CommuteAttributes.ContentState,
        now: Date
    ) -> Countdown {
        let dates = [
            state.train?.countdown(now: now),
            state.bus?.countdown(now: now)
        ].compactMap { $0?.futureDate }
        if let soonest = dates.min() {
            return .future(soonest)
        }
        return .none
    }

    private func compactTimelineEntries(
        state: CommuteAttributes.ContentState
    ) -> [Date] {
        var dates: [Date] = []
        if let train = state.train {
            dates += train.upcomingArrivals
            dates.append(train.nextArrival)
        }
        if let bus = state.bus {
            dates += bus.upcomingArrivals
            dates.append(bus.nextArrival)
        }
        let now = Date.now
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

// Second future arrival after the primary, looking first at the
// `upcoming` list, then at `fallback`. Used for the secondary line in
// Dynamic Island's expanded trailing stack.
private func secondaryFutureArrival(
    upcoming: [Date],
    now: Date,
    fallback: Date?
) -> Date? {
    let futures = upcoming.filter { $0 > now }
    if futures.count >= 2 { return futures[1] }
    if let fallback, fallback > now { return fallback }
    return nil
}

private extension CommuteAttributes.TrainLeg {
    func countdown(now: Date) -> Countdown {
        upcomingArrivals.firstFuture(now: now, fallback: nextArrival)
    }
}

private extension CommuteAttributes.BusLeg {
    func countdown(now: Date) -> Countdown {
        upcomingArrivals.firstFuture(now: now, fallback: nextArrival)
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: CommuteAttributes.ContentState

    var body: some View {
        content
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.vertical, ChicagoSpacing.sm)
    }

    // Two legs pinned → render side-by-side so the combined activity fits the
    // ~160pt lock-screen height budget. One leg → use the original full-width
    // row, which already breathes in that case.
    @ViewBuilder
    private var content: some View {
        if let train = state.train, let bus = state.bus {
            let trainLine = LineColor(rawValue: train.lineColorRaw) ?? .red
            HStack(alignment: .top, spacing: ChicagoSpacing.sm) {
                LegColumn(
                    accentColor: trainLine.swiftUIColor,
                    badge: AnyView(RouteBadge(line: trainLine, size: .sm)),
                    headline: "→ \(train.destination)",
                    subhead: train.stopName,
                    nextArrival: train.nextArrival,
                    followingArrival: train.followingArrival,
                    upcomingArrivals: train.upcomingArrivals,
                    confidenceMarks: train.confidenceMarks,
                    alert: train.alertHeadline
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: ChicagoSpacing.Stroke.hairline)

                LegColumn(
                    accentColor: ChicagoPalette.OnDarkSafe.gold,
                    badge: AnyView(RouteBadge(bus: bus.routeLabel, size: .sm)),
                    headline: bus.directionLabel,
                    subhead: bus.stopName,
                    nextArrival: bus.nextArrival,
                    followingArrival: bus.followingArrival,
                    upcomingArrivals: bus.upcomingArrivals,
                    confidenceMarks: bus.confidenceMarks,
                    alert: bus.alertHeadline
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let train = state.train {
            let line = LineColor(rawValue: train.lineColorRaw) ?? .red
            LegRow(
                accentColor: line.swiftUIColor,
                badge: AnyView(RouteBadge(line: line, size: .sm)),
                headline: "→ \(train.destination)",
                subhead: train.stopName,
                nextArrival: train.nextArrival,
                followingArrival: train.followingArrival,
                upcomingArrivals: train.upcomingArrivals,
                confidenceMarks: train.confidenceMarks,
                alert: train.alertHeadline
            )
        } else if let bus = state.bus {
            LegRow(
                accentColor: ChicagoPalette.OnDarkSafe.gold,
                badge: AnyView(RouteBadge(bus: bus.routeLabel, size: .sm)),
                headline: bus.directionLabel,
                subhead: bus.stopName,
                nextArrival: bus.nextArrival,
                followingArrival: bus.followingArrival,
                upcomingArrivals: bus.upcomingArrivals,
                confidenceMarks: bus.confidenceMarks,
                alert: bus.alertHeadline
            )
        }
    }

}

private struct LegRow: View {
    let accentColor: Color
    let badge: AnyView
    let headline: String
    let subhead: String
    let nextArrival: Date
    let followingArrival: Date?
    let upcomingArrivals: [Date]
    let confidenceMarks: [ArrivalConfidenceMark]
    let alert: String?

    var body: some View {
        // The dot strip *is* the time signal — the rightmost edge is 30 min
        // out, dots show the next arrivals on a position scale, and the
        // periodic schedule ticks the body every 30 s so the dots slide
        // left smoothly as time passes (continuous fraction-based
        // positioning; `HeadwayDotStrip` drops a dot when its delta goes
        // negative). Previously a `Text(_, style: .relative)` counted
        // alongside the dots, but it kept ticking past zero into
        // "elapsed since the missed train" territory — confusing and, per
        // the user, stressful.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                HStack(spacing: ChicagoSpacing.sm) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(accentColor)
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: ChicagoSpacing.xs) {
                            badge
                            Text(headline)
                                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                                .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                                .lineLimit(1)
                        }
                        Text(subhead)
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                            .foregroundStyle(ChicagoPalette.OnDarkSafe.secondary)
                            .lineLimit(1)
                        if let alert {
                            Label(alert, systemImage: "exclamationmark.triangle.fill")
                                .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.OnDarkSafe.starRed)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !dotStripArrivals.isEmpty {
                    HeadwayDotStrip(
                        arrivals: dotStripArrivals,
                        accent: accentColor,
                        now: timeline.date,
                        confidenceTones: confidenceTones,
                        style: .onDark
                    )
                    .padding(.leading, 4 + ChicagoSpacing.sm)  // align with the text column
                }
            }
        }
    }

    /// Use the rich list when shipped; fall back to the two scalar fields
    /// (older saved state from the previous app version).
    private var dotStripArrivals: [Date] {
        if !upcomingArrivals.isEmpty { return upcomingArrivals }
        return [nextArrival, followingArrival].compactMap { $0 }
    }

    /// Tones aligned to `dotStripArrivals` by index. Empty array (or any
    /// trailing nils when the leg has more arrivals than marks) leaves
    /// the dot strip at its baseline opacity.
    private var confidenceTones: [ArrivalConfidenceMark.Tone?] {
        guard !confidenceMarks.isEmpty else { return [] }
        return dotStripArrivals.map { date in
            confidenceMarks.first { $0.arrivalAt == date }?.tone
        }
    }
}

// Half-width column variant used when both legs are pinned. Same visual
// vocabulary as `LegRow` — accent bar, badge, headline, ETA, dot-strip,
// alert — rearranged vertically so two columns fit side-by-side in the
// lock-screen height budget.
private struct LegColumn: View {
    let accentColor: Color
    let badge: AnyView
    let headline: String
    let subhead: String
    let nextArrival: Date
    let followingArrival: Date?
    let upcomingArrivals: [Date]
    let confidenceMarks: [ArrivalConfidenceMark]
    let alert: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            HStack(alignment: .top, spacing: ChicagoSpacing.sm) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(accentColor)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        badge
                        Text(headline)
                            .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                            .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(subhead)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.OnDarkSafe.secondary)
                        .lineLimit(1)
                    if !dotStripArrivals.isEmpty {
                        HeadwayDotStrip(
                            arrivals: dotStripArrivals,
                            accent: accentColor,
                            now: timeline.date,
                            confidenceTones: confidenceTones,
                            style: .onDark
                        )
                    }
                    if let alert {
                        Label(alert, systemImage: "exclamationmark.triangle.fill")
                            .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.OnDarkSafe.starRed)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dotStripArrivals: [Date] {
        if !upcomingArrivals.isEmpty { return upcomingArrivals }
        return [nextArrival, followingArrival].compactMap { $0 }
    }

    private var confidenceTones: [ArrivalConfidenceMark.Tone?] {
        guard !confidenceMarks.isEmpty else { return [] }
        return dotStripArrivals.map { date in
            confidenceMarks.first { $0.arrivalAt == date }?.tone
        }
    }
}
