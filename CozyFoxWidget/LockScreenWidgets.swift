import ChicagoTheme
import SwiftData
import SwiftUI
import TransitCache
import TransitDomain
import TransitModels
import TransitUI
import WidgetKit

struct LockScreenInlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CozyFoxInline", provider: LockScreenProvider()) { entry in
            inlineView(for: entry)
        }
        .configurationDisplayName("Next train")
        .description("Shows the next train arrival in your status bar.")
        .supportedFamilies([.accessoryInline])
    }

    @ViewBuilder
    private func inlineView(for entry: LockScreenEntry) -> some View {
        if let arrival = entry.snapshot.trainArrivals.first {
            Text("\(arrival.line.shortName) \(ArrivalFormatter.label(for: arrival).shortText)")
        } else {
            Text("Cozy Fox")
        }
    }
}

struct LockScreenRectangularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CozyFoxRectangular", provider: LockScreenProvider()) { entry in
            RectangularLockView(entry: entry)
        }
        .configurationDisplayName("Two next arrivals")
        .description("Compact rectangular view of upcoming arrivals.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LockScreenCircularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CozyFoxCircular", provider: LockScreenProvider()) { entry in
            CircularLockView(entry: entry)
        }
        .configurationDisplayName("Next train minutes")
        .description("Just the minutes till your next train.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct RectangularLockView: View {
    let entry: LockScreenEntry

    var body: some View {
        if let arrival = entry.snapshot.trainArrivals.first {
            let line = arrival.line
            let upcoming = entry.snapshot.trainArrivals
                .filter { $0.line == line }
                .prefix(6)
                .map(\.arrivalAt)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ChicagoSpacing.xs) {
                    RouteBadge(line: line, size: .sm)
                    Text(arrival.destinationName)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .lineLimit(1)
                }
                ForEach(entry.snapshot.trainArrivals.prefix(2), id: \.id) { item in
                    Text(ArrivalFormatter.label(for: item).shortText)
                        .font(ChicagoTypography.bigNumber(16, relativeTo: .callout))
                }
            }
        } else {
            Text("No data")
        }
    }
}

struct CircularLockView: View {
    let entry: LockScreenEntry

    var body: some View {
        if let arrival = entry.snapshot.trainArrivals.first {
            let mins = max(0, arrival.minutesUntilArrival())
            VStack(spacing: 0) {
                Text("\(mins)")
                    .font(ChicagoTypography.bigNumber(22, relativeTo: .title3))
                Text("MIN")
                    .font(ChicagoTypography.displaySM(relativeTo: .caption2))
                    .tracking(0.5)
            }
        } else {
            ChicagoStar()
                .fill(.tint)
                .frame(width: 16, height: 16)
        }
    }
}

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let snapshot: TransitSnapshot
}

struct LockScreenProvider: TimelineProvider {
    typealias Entry = LockScreenEntry

    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(LockScreenEntry(date: .now, snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let snap = load()
        let now = Date()
        let entries = (0..<5).map { offset in
            LockScreenEntry(date: now.addingTimeInterval(Double(offset) * 90), snapshot: snap)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(450))))
    }

    private func load() -> TransitSnapshot {
        guard let container = try? ModelContainer.sharedAppGroup() else { return .empty }
        return SnapshotReader(container: container).loadSnapshot()
    }
}
