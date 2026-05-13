import ActivityKit
import SwiftUI
import WidgetKit
import TransitModels
import TransitUI

// MARK: - Palette
//
// Live Activities don't reliably inherit the device's colorScheme — iOS often
// renders them in a "dark" internal context regardless of `activityBackgroundTint`,
// which is what produced white-on-white text in earlier builds. We use a
// fixed dark chrome + explicit light colors so nothing depends on the SwiftUI
// environment guessing the right color scheme.

private let activityBackground = Color(red: 0.10, green: 0.10, blue: 0.12)
private let primaryText = Color.white
private let secondaryText = Color.white.opacity(0.70)
private let tertiaryText = Color.white.opacity(0.50)
private let alertText = Color(red: 1.00, green: 0.66, blue: 0.20)
private let busAccent = Color(red: 0.99, green: 0.74, blue: 0.20)

struct CommuteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CommuteAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(activityBackground)
                .activitySystemActionForegroundColor(primaryText)
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
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(primaryText)
                }
            } minimal: {
                compactMarks(state: context.state)
            }
        }
    }

    // MARK: - Expanded Dynamic Island regions

    @ViewBuilder
    private func expandedLeading(state: CommuteAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let train = state.train {
                trainLegRow(train, compact: true)
            }
            if let bus = state.bus {
                busLegRow(bus, compact: true)
            }
        }
    }

    @ViewBuilder
    private func expandedTrailing(state: CommuteAttributes.ContentState) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
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
                .font(.caption)
                .foregroundStyle(alertText)
                .lineLimit(2)
        }
    }

    private func compactMarks(state: CommuteAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            if let train = state.train {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LineColor(rawValue: train.lineColorRaw)?.swiftUIColor ?? .accentColor)
                    .frame(width: 10, height: 12)
            }
            if state.bus != nil {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(busAccent)
            }
        }
    }

    // MARK: - Leg rows

    private func trainLegRow(_ leg: CommuteAttributes.TrainLeg, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LineColor(rawValue: leg.lineColorRaw)?.swiftUIColor ?? .accentColor)
                    .frame(width: 10, height: 12)
                Text("→ \(leg.destination)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
            }
            Text(leg.stopName)
                .font(.caption2)
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
    }

    private func busLegRow(_ leg: CommuteAttributes.BusLeg, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "bus.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(busAccent)
                Text("\(leg.routeLabel) → \(leg.destination)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
            }
            Text(leg.stopName)
                .font(.caption2)
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
    }

    private func arrivalStack(next: Date, following: Date?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(next, style: .relative)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(primaryText)
            if let following {
                Text(following, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(secondaryText)
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
        VStack(alignment: .leading, spacing: 10) {
            if let train = state.train {
                LegRow(
                    accentBar: AnyView(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LineColor(rawValue: train.lineColorRaw)?.swiftUIColor ?? .accentColor)
                    ),
                    badgeIcon: nil,
                    headline: "\(train.routeLabel) → \(train.destination)",
                    subhead: train.stopName,
                    nextArrival: train.nextArrival,
                    followingArrival: train.followingArrival,
                    alert: train.alertHeadline
                )
            }
            if state.train != nil, state.bus != nil {
                Divider().background(Color.white.opacity(0.18))
            }
            if let bus = state.bus {
                LegRow(
                    accentBar: AnyView(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(busAccent)
                    ),
                    badgeIcon: "bus.fill",
                    headline: "\(bus.routeLabel) · \(bus.directionLabel)",
                    subhead: bus.stopName,
                    nextArrival: bus.nextArrival,
                    followingArrival: bus.followingArrival,
                    alert: bus.alertHeadline
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct LegRow: View {
    let accentBar: AnyView
    let badgeIcon: String?
    let headline: String
    let subhead: String
    let nextArrival: Date
    let followingArrival: Date?
    let alert: String?

    var body: some View {
        HStack(spacing: 12) {
            accentBar.frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let badgeIcon {
                        Image(systemName: badgeIcon)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(busAccent)
                    }
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }
                Text(subhead)
                    .font(.caption)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                if let alert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(alertText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(nextArrival, style: .relative)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(primaryText)
                if let followingArrival {
                    Text(followingArrival, style: .relative)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(secondaryText)
                }
            }
        }
    }
}
