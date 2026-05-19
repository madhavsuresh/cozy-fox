import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels

struct DepartureLadderDebugCard: View {
    @Environment(AppViewModel.self) private var model
    @State private var viewModel = DepartureLadderDebugViewModel()
    @State private var mileMode: DepartureLadderDebugViewModel.MileMode = .walk

    var body: some View {
        ChicagoCard(
            title: cardTitle,
            eyebrow: "Debug — departure ladder",
            accent: ChicagoPalette.flagBlue
        ) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                mileModeToggle
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
        .onChange(of: mileMode) { _, _ in rebuild() }
    }

    @ViewBuilder
    private var mileModeToggle: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Text("First/last mile")
                .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.dark)
            Picker("First/last mile", selection: $mileMode) {
                Text("Walk").tag(DepartureLadderDebugViewModel.MileMode.walk)
                Text("Bike").tag(DepartureLadderDebugViewModel.MileMode.bike)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
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
        case .noCandidates: "No pinned line, Metra, bus, or Intercampus route covers Home → Work."
        }
    }

    @ViewBuilder
    private func rowView(_ row: DepartureLadderRow, ladderGeneratedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Leave by \(timeOfDay(row.leaveByAt))")
                        .font(ChicagoTypography.body(.bold, relativeTo: .body))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    if let boardingAt = row.boardingAt {
                        Text("Board \(timeOfDay(boardingAt))")
                            .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.Gray.dark)
                            .monospacedDigit()
                    }
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
            if !row.legs.isEmpty {
                legsView(row.legs)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func legsView(_ legs: [DepartureLadderLeg]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(legs) { leg in
                HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
                    Text(modeSymbol(leg.mode))
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.dark)
                        .frame(minWidth: 18, alignment: .leading)
                    Text(leg.label)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("\(timeOfDay(leg.arrivalMean)) · \(minutesString(leg.meanSeconds))")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .monospacedDigit()
                }
            }
        }
        .padding(.leading, ChicagoSpacing.xs)
    }

    private func modeSymbol(_ mode: LegMode) -> String {
        switch mode {
        case .walk: "→"
        case .ctaTrain: "L"
        case .ctaBus: "B"
        case .metra: "M"
        case .intercampus: "IC"
        case .divvyClassic, .divvyEBike, .freeBikeParking: "B+"
        case .finalMile: "→"
        }
    }

    private func minutesString(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes) min"
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
        if !viewModel.candidateSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(viewModel.candidateSummaries, id: \.self) { summary in
                    Text(summary)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                }
            }
        }
    }

    private func rebuild() {
        viewModel.rebuild(
            snapshot: model.snapshot,
            prefs: model.preferences.loadRoutePreferences(),
            anchors: model.preferences.loadCommuteAnchors(),
            walkingResolver: model.walkingResolver,
            walkSpeedEstimate: model.walkingStore.walkSpeedEstimate,
            mileMode: mileMode
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
