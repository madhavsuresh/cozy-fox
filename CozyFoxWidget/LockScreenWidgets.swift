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
        if let arrival = entry.displayedTrainArrivals.first {
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
        if let arrival = entry.displayedTrainArrivals.first {
            let line = arrival.line
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ChicagoSpacing.xs) {
                    RouteBadge(line: line, size: .sm)
                    Text(arrival.destinationName)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .lineLimit(1)
                }
                ForEach(entry.displayedTrainArrivals.prefix(2), id: \.id) { item in
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
        if let arrival = entry.displayedTrainArrivals.first {
            let mins = max(0, arrival.minutesUntilArrival())
            VStack(spacing: 0) {
                Text("\(mins)")
                    .font(ChicagoTypography.bigNumber(22, relativeTo: .title3))
                Text("MIN")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
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
    let preferences: UserRoutePreferences

    var displayedTrainArrivals: [Arrival] {
        if let tripTrain = preferences.plannedTripPin?.train {
            return snapshot.trainArrivals
                .filter { $0.line == tripTrain.line }
                .filter { tripTrain.stationId == nil || $0.stationId == tripTrain.stationId }
                .filter { tripTrain.destinationName == nil || $0.destinationName == tripTrain.destinationName }
        }
        if let pinned = preferences.pinnedLine {
            return snapshot.trainArrivals
                .filter { $0.line == pinned }
                .filter { preferences.pinnedStationId == nil || $0.stationId == preferences.pinnedStationId }
                .filter { arrival in
                    preferences.pinnedTrainDestinations?
                        .contains(arrival.destinationName) ?? true
                }
        }
        guard preferences.isModeVisible(.trains),
              let first = snapshot.trainArrivals.first(where: {
                  preferences.isTrainLineVisible($0.line)
              }) else { return [] }
        return snapshot.trainArrivals.filter { $0.line == first.line }
    }
}

struct LockScreenProvider: TimelineProvider {
    typealias Entry = LockScreenEntry

    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: .now, snapshot: .empty, preferences: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        completion(LockScreenEntry(date: .now, snapshot: load(), preferences: loadPreferences()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let snap = load()
        let prefs = loadPreferences()
        let now = Date()
        let entries = (0..<5).map { offset in
            LockScreenEntry(
                date: now.addingTimeInterval(Double(offset) * 90),
                snapshot: snap,
                preferences: prefs
            )
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(450))))
    }

    private func load() -> TransitSnapshot {
        guard let container = try? ModelContainer.sharedAppGroup() else { return .empty }
        return SnapshotReader(container: container).loadSnapshot()
    }

    private func loadPreferences() -> UserRoutePreferences {
        PreferencesStore().loadRoutePreferences()
    }
}
