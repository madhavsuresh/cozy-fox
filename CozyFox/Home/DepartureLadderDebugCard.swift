import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels

struct DepartureLadderDebugCard: View {
    @Environment(AppViewModel.self) private var model
    @State private var viewModel = DepartureLadderDebugViewModel()

    var body: some View {
        ChicagoCard(
            title: cardTitle,
            eyebrow: "Debug — departure ladder",
            accent: ChicagoPalette.flagBlue
        ) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                if let ladder = viewModel.ladder {
                    if let headline = ladder.headline {
                        Text(headline)
                            .font(ChicagoTypography.body(.bold, relativeTo: .body))
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                    }
                    if ladder.rows.isEmpty {
                        Text("No live departures inside the 90-min horizon.")
                            .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    } else {
                        ForEach(ladder.rows) { row in
                            rowView(row, ladderGeneratedAt: ladder.generatedAt)
                        }
                    }
                    lineHealthFooter(snapshots: ladder.lineHealth)
                    stationFootnote
                } else {
                    statusPlaceholder
                    stationFootnote
                }
            }
        }
        .onAppear { rebuild() }
        .onChange(of: model.snapshot) { _, _ in rebuild() }
        .onChange(of: model.pinRevision) { _, _ in rebuild() }
    }

    private var cardTitle: String {
        if let ladder = viewModel.ladder {
            return ladder.destinationTitle
        }
        return "Work"
    }

    @ViewBuilder
    private var statusPlaceholder: some View {
        Text(statusMessage)
            .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
            .foregroundStyle(ChicagoPalette.Gray.medium)
    }

    private var statusMessage: String {
        switch viewModel.status {
        case .ready: "Computing…"
        case .missingHome: "Set a Home anchor in Settings."
        case .missingWork: "Set a Work anchor in Settings."
        case .missingPinnedLine: "Pin a train line on the dashboard."
        case .noNearbyStationOnLine: "No station on the pinned line is near Home and Work."
        case .noLiveData: "Waiting for live train arrivals."
        }
    }

    @ViewBuilder
    private func rowView(_ row: DepartureLadderRow, ladderGeneratedAt: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Leave by \(timeOfDay(row.leaveByAt))")
                    .font(ChicagoTypography.body(.bold, relativeTo: .body))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Text("Arrive \(timeOfDay(row.arrivalAt.low))–\(timeOfDay(row.arrivalAt.high))")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.primaryLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.dark)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.risk.label)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(riskColor(row.risk))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func lineHealthFooter(snapshots: [LineHealthSnapshot]) -> some View {
        if !snapshots.isEmpty {
            HStack(spacing: ChicagoSpacing.xs) {
                ForEach(snapshots) { snap in
                    Text("\(snap.route): \(snap.state.rawValue)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                }
            }
        }
    }

    @ViewBuilder
    private var stationFootnote: some View {
        if let boarding = viewModel.boardingStationName,
           let alighting = viewModel.alightingStationName {
            Text("Board \(boarding) → alight \(alighting)")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    private func rebuild() {
        viewModel.rebuild(
            snapshot: model.snapshot,
            prefs: model.preferences.loadRoutePreferences(),
            anchors: model.preferences.loadCommuteAnchors(),
            walkingResolver: model.walkingResolver,
            walkSpeedEstimate: model.walkingStore.walkSpeedEstimate
        )
    }

    private func riskColor(_ risk: WaitReasonableness) -> Color {
        switch risk {
        case .goodWait, .acceptableWait: ChicagoPalette.Gray.dark
        case .bunched: ChicagoPalette.flagBlue
        case .riskyWait: ChicagoPalette.gold
        case .badGap, .feedUnreliable: ChicagoPalette.starRed
        case .unknown: ChicagoPalette.Gray.medium
        }
    }

    private func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }
}
