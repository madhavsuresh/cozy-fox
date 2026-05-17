import SwiftUI
import ChicagoTheme

/// Tiny "last refreshed N seconds ago" dot + label that lives in the
/// header row of each pinned card. The intent is for the user to
/// glance at a pinned card and immediately know whether the times
/// they're reading are live — without ever pulling to refresh.
///
/// Visual hierarchy is deliberately quiet: a 5pt dot and `.caption2`
/// text, both colored against the medium-gray neutral until the data
/// actually ages. The dot doesn't pulse — pulsing risks reading as a
/// loading spinner, which is the opposite of the message we want.
///
/// `Staleness` is the source of truth for thresholds; this view just
/// renders it. Update `Staleness.liveCutoff` / `agingCutoff` /
/// `staleCutoff` if the upstream cadence ever changes.
struct StalenessIndicator: View {
    let staleness: Staleness

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(staleness.label)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .monospacedDigit()
                .foregroundStyle(textColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(staleness.accessibilityLabel)
    }

    private var dotColor: Color {
        switch staleness {
        case .unknown: return ChicagoPalette.Gray.light
        case .live: return ChicagoPalette.green
        case .current: return ChicagoPalette.green.opacity(0.65)
        case .aging: return ChicagoPalette.gold
        case .stale: return ChicagoPalette.starRed
        }
    }

    private var textColor: Color {
        switch staleness {
        case .unknown, .live, .current: return ChicagoPalette.Gray.medium
        case .aging: return ChicagoPalette.Gray.dark
        case .stale: return ChicagoPalette.starRed
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StalenessIndicator(staleness: .unknown)
        StalenessIndicator(staleness: .live)
        StalenessIndicator(staleness: .current(seconds: 45))
        StalenessIndicator(staleness: .aging(minutes: 2))
        StalenessIndicator(staleness: .stale(minutes: 7))
    }
    .padding()
}
