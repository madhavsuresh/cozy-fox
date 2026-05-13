import ActivityKit
import ChicagoTheme
import SwiftUI
import TransitModels
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
                if let date = soonestDate(state: context.state) {
                    Text(date, style: .relative)
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
                arrivalStack(next: train.nextArrival, following: train.followingArrival)
            }
            if let bus = state.bus {
                arrivalStack(next: bus.nextArrival, following: bus.followingArrival)
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

    private func arrivalStack(next: Date, following: Date?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(next, style: .relative)
                .font(ChicagoTypography.bigNumber(18, relativeTo: .subheadline))
                .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
            if let following {
                Text(following, style: .relative)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.tertiary)
            }
        }
    }

    private func soonestDate(state: CommuteAttributes.ContentState) -> Date? {
        [state.train?.nextArrival, state.bus?.nextArrival]
            .compactMap { $0 }
            .min()
    }
}

// MARK: - Lock screen

private struct LockScreenView: View {
    let state: CommuteAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            if let train = state.train {
                let line = LineColor(rawValue: train.lineColorRaw) ?? .red
                LegRow(
                    accentColor: line.swiftUIColor,
                    badge: AnyView(RouteBadge(line: line, size: .sm)),
                    headline: "→ \(train.destination)",
                    subhead: train.stopName,
                    nextArrival: train.nextArrival,
                    followingArrival: train.followingArrival,
                    alert: train.alertHeadline
                )
            }
            if state.train != nil, state.bus != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: ChicagoSpacing.Stroke.hairline)
            }
            if let bus = state.bus {
                LegRow(
                    accentColor: ChicagoPalette.OnDarkSafe.gold,
                    badge: AnyView(RouteBadge(bus: bus.routeLabel, size: .sm)),
                    headline: bus.directionLabel,
                    subhead: bus.stopName,
                    nextArrival: bus.nextArrival,
                    followingArrival: bus.followingArrival,
                    alert: bus.alertHeadline
                )
            }
        }
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.sm)
    }
}

private struct LegRow: View {
    let accentColor: Color
    let badge: AnyView
    let headline: String
    let subhead: String
    let nextArrival: Date
    let followingArrival: Date?
    let alert: String?

    var body: some View {
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
            Spacer(minLength: ChicagoSpacing.sm)
            VStack(alignment: .trailing, spacing: 0) {
                Text(nextArrival, style: .relative)
                    .font(ChicagoTypography.bigNumber(20, relativeTo: .title3))
                    .foregroundStyle(ChicagoPalette.OnDarkSafe.primary)
                if let followingArrival {
                    Text(followingArrival, style: .relative)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundStyle(ChicagoPalette.OnDarkSafe.secondary)
                }
            }
        }
    }
}
