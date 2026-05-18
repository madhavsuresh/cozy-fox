import SwiftUI
import ChicagoTheme

/// Tiny "last refreshed N seconds ago" dot + label that lives in the
/// header row of each pinned card. The intent is for the user to
/// glance at a pinned card and immediately know whether the times
/// they're reading are live — without ever pulling to refresh.
///
/// Visual hierarchy is deliberately quiet: a 6pt dot and `.caption2`
/// text, both colored against the medium-gray neutral until the data
/// actually ages. The dot only flashes while a refresh is in flight, so
/// the rider can tell that the visible age is about to be replaced.
///
/// `Staleness` is the source of truth for thresholds; this view just
/// renders it. Update `Staleness.liveCutoff` / `agingCutoff` /
/// `staleCutoff` if the upstream cadence ever changes.
struct StalenessIndicator: View {
    let staleness: Staleness
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashPhase = false

    init(staleness: Staleness, isRefreshing: Bool = false) {
        self.staleness = staleness
        self.isRefreshing = isRefreshing
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .opacity(dotOpacity)
                .scaleEffect(dotScale)
            Text(staleness.label)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .monospacedDigit()
                .foregroundStyle(textColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task(id: shouldFlash) {
            if shouldFlash {
                flashPhase = false
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    flashPhase = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    flashPhase = false
                }
            }
        }
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

    private var shouldFlash: Bool {
        isRefreshing && !reduceMotion
    }

    private var dotOpacity: Double {
        shouldFlash && flashPhase ? 0.28 : 1
    }

    private var dotScale: CGFloat {
        shouldFlash && flashPhase ? 1.45 : 1
    }

    private var accessibilityLabel: String {
        isRefreshing
            ? "Updating. \(staleness.accessibilityLabel)"
            : staleness.accessibilityLabel
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StalenessIndicator(staleness: .unknown)
        StalenessIndicator(staleness: .live)
        StalenessIndicator(staleness: .live, isRefreshing: true)
        StalenessIndicator(staleness: .current(seconds: 45))
        StalenessIndicator(staleness: .aging(minutes: 2))
        StalenessIndicator(staleness: .stale(minutes: 7))
    }
    .padding()
}
