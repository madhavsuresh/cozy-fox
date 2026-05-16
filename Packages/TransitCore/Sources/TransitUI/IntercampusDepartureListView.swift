import ChicagoTheme
import SwiftUI
import TransitModels

/// A short scannable list of upcoming Intercampus departures: one row
/// per arrival, clock time on the left and a relative countdown to its
/// right. Used as the always-on timetable readout beneath the headline
/// BigNumber. Intended for schedule-source data — the headline and the
/// (optional) dot strip carry the live, traffic-adjusted view; this
/// list is the stable timetable the rider plans against. When the
/// headline drifts from the list's countdown for the same shuttle, the
/// delta surfaces the live delay without any extra annotation.
public struct IntercampusDepartureListView: View {
    public let arrivals: [IntercampusArrival]
    public let maxCount: Int
    public let accent: Color
    public let now: Date

    public init(
        arrivals: [IntercampusArrival],
        maxCount: Int = 5,
        accent: Color,
        now: Date = .now
    ) {
        self.arrivals = arrivals
        self.maxCount = maxCount
        self.accent = accent
        self.now = now
    }

    public var body: some View {
        if displayed.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                ForEach(displayed, id: \.id) { arrival in
                    row(arrival)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var displayed: [IntercampusArrival] {
        // Hide arrivals already comfortably past so we don't show "0 min"
        // for a shuttle that's clearly gone.
        let earliest = now.addingTimeInterval(-30)
        return Array(arrivals.filter { $0.arrivalAt >= earliest }.prefix(maxCount))
    }

    private func row(_ arrival: IntercampusArrival) -> some View {
        let delayed = arrival.isDelayed
        let timeColor: Color = delayed ? ChicagoPalette.starRed : ChicagoPalette.Gray.darkest
        let countdownColor: Color = delayed ? ChicagoPalette.starRed : ChicagoPalette.Gray.medium
        return HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.sm) {
            Text(Self.clockText(arrival.arrivalAt))
                .font(timeFont)
                .foregroundStyle(timeColor)
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)
            Text(Self.countdownText(arrival.arrivalAt, from: now))
                .font(countdownFont)
                .foregroundStyle(countdownColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var timeFont: Font {
        ChicagoTypography.body(.medium, size: 16, relativeTo: .subheadline)
            .monospacedDigit()
    }

    private var countdownFont: Font {
        ChicagoTypography.body(.regular, relativeTo: .caption)
            .monospacedDigit()
    }

    static func clockText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func countdownText(_ date: Date, from now: Date) -> String {
        let delta = max(0, date.timeIntervalSince(now))
        let totalMinutes = Int((delta / 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    private var accessibilityLabel: String {
        let parts = displayed.map { arrival -> String in
            let clock = Self.clockText(arrival.arrivalAt)
            let countdown = Self.countdownText(arrival.arrivalAt, from: now)
            return "\(clock) in \(countdown)"
        }
        return "Upcoming departures: " + parts.joined(separator: ", ")
    }
}
