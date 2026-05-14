import ChicagoTheme
import CoreLocation
import MapKit
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

struct DashboardScreen: View {
    @Environment(AppViewModel.self) private var model
    @State private var pinnedLine: LineColor?
    @State private var pinnedStationId: Int?
    @State private var pinnedTrainDestination: String?
    @State private var pinnedBusRoute: String?
    @State private var pinnedBusDirection: String?
    @State private var pinnedBusStopId: Int?
    @State private var pinnedMetraRoute: String?
    @State private var pinnedMetraStationId: String?
    @State private var pinnedMetraDirectionId: Int?
    @State private var pinnedMetraDestination: String?
    @State private var pinSource: RoutePinSource = .manual
    @State private var autoPinnedDirection: CommuteDirection?
    @State private var plannedTripPin: PlannedTripPin?
    @State private var commuteAnchors: CommuteAnchors = .empty
    @State private var goHomeSelected: Bool = false
    @State private var allowMultimodalHomePin: Bool = true
    @State private var isPinningHome: Bool = false
    @State private var homePinStatusText: String?
    @State private var homePinStatusIsError: Bool = false
    @State private var homeTripOptions: [HomeTripOption] = []
    @State private var selectedHomeTripOptionId: UUID?
    @State private var selectedTrainChoiceId: String?
    @State private var selectedBusChoiceId: String?
    @State private var selectedMetraChoiceId: String?
    @State private var isHomeEntryPresented: Bool = false
    @State private var isTripPlannerPresented: Bool = false
    /// Flipped to `true` 300ms after the pinned-line card mounts (or
    /// re-mounts at a new origin/line) if MapKit hasn't produced any
    /// walking data yet. While false, the chip strip shows shimmer
    /// placeholders so the user doesn't see a stale Haversine ordering
    /// for a flicker before MapKit refines.
    @State private var allowHaversineFallback: Bool = false

    private let tripPlanner = TripPlanner()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    flagHeader
                    homePinControl
                    if let plannedTripPin {
                        activeHomeTripCard(plannedTripPin)
                    } else if !homeTripOptions.isEmpty {
                        homeTripOptionsCard
                    }
                    alertsCard
                    liveUpdatesBar
                    if shouldShowAutopinBanner {
                        contextBanner
                    }
                    linePickerCard
                    if let line = pinnedLine {
                        pinnedLineCard(line: line)
                    }
                    busRoutePickerCard
                    if let route = pinnedBusRoute {
                        pinnedBusCard(route: route)
                    }
                    metraRoutePickerCard
                    if let route = pinnedMetraRoute {
                        pinnedMetraCard(route: route)
                    }
                    tripPlannerCard
                    bikeCard
                    nearYouSection
                }
                .padding(ChicagoSpacing.md)
            }
            .background(ChicagoPalette.Surface.background)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ChicagoStar()
                            .fill(ChicagoPalette.starRed)
                            .frame(width: 18, height: 18)
                        Text("Cozy Fox")
                            .font(ChicagoTypography.displayMD(relativeTo: .headline))
                            .tracking(0.5)
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                    }
                    .accessibilityLabel("Cozy Fox")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .tint(ChicagoPalette.flagBlue)
            .refreshable { await model.refreshIfNeeded(force: true) }
            .onAppear { reloadPinnedFromPreferences() }
            .onChange(of: model.pinRevision) { _, _ in reloadPinnedFromPreferences() }
            .onChange(of: allowMultimodalHomePin) { _, _ in
                if goHomeSelected, plannedTripPin == nil, !isPinningHome {
                    planHomeRouteOptions()
                }
            }
            .sheet(isPresented: $isHomeEntryPresented, onDismiss: reloadPinnedFromPreferences) {
                HomeAddressEntry()
                    .environment(model)
            }
            .sheet(isPresented: $isTripPlannerPresented, onDismiss: reloadPinnedFromPreferences) {
                TripPlannerScreen()
                    .environment(model)
            }
        }
    }

    private func reloadPinnedFromPreferences() {
        let prefs = model.preferences.loadRoutePreferences()
        pinnedLine = prefs.pinnedLine
        pinnedStationId = prefs.pinnedStationId
        pinnedTrainDestination = prefs.pinnedTrainDestination
        pinnedBusRoute = prefs.pinnedBusRoute
        pinnedBusDirection = prefs.pinnedBusDirection
        pinnedBusStopId = prefs.pinnedBusStopId
        pinnedMetraRoute = prefs.pinnedMetraRoute
        pinnedMetraStationId = prefs.pinnedMetraStationId
        pinnedMetraDirectionId = prefs.pinnedMetraDirectionId
        pinnedMetraDestination = prefs.pinnedMetraDestination
        pinSource = prefs.pinSource
        autoPinnedDirection = prefs.autoPinnedDirection
        plannedTripPin = prefs.plannedTripPin
        goHomeSelected = prefs.plannedTripPin?.destination == .home
        commuteAnchors = model.preferences.loadCommuteAnchors()
    }

    // MARK: - Flag header band

    /// A thin Chicago-flag-style header stripe — two narrow Flag Blue
    /// bands enclosing a white field carrying a single red star. Civic
    /// visual identity in 14 vertical points.
    private var flagHeader: some View {
        VStack(spacing: 0) {
            band
            ZStack {
                Rectangle().fill(Color.white)
                ChicagoStar()
                    .fill(ChicagoPalette.starRed)
                    .frame(width: 10, height: 10)
            }
            .frame(height: 14)
            band
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm))
        .accessibilityHidden(true)
    }

    private var band: some View {
        Rectangle().fill(ChicagoPalette.flagBlue).frame(height: 5)
    }

    // MARK: - Go home

    private var homePinControl: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            HStack(spacing: ChicagoSpacing.sm) {
                Toggle(isOn: Binding(
                    get: { goHomeSelected },
                    set: { setGoHomeSelected($0) }
                )) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        Image(systemName: "house.fill")
                            .foregroundStyle(ChicagoPalette.flagBlue)
                        Text("Go home")
                            .font(ChicagoTypography.displaySM(relativeTo: .callout))
                            .tracking(0.5)
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                    }
                }
                .tint(ChicagoPalette.flagBlue)
                .disabled(isPinningHome)

                Toggle("Multimodal", isOn: $allowMultimodalHomePin)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .tint(ChicagoPalette.flagBlue)
                    .fixedSize()
            }

            if isPinningHome {
                Label("Planning route options…", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            if let text = homePinStatusText {
                Label(text, systemImage: homePinStatusIsError ? "exclamationmark.triangle.fill" : "pin.fill")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(homePinStatusIsError ? ChicagoPalette.starRed : ChicagoPalette.Gray.medium)
            } else if commuteAnchors.home == nil {
                homeEntryPrompt("Enter home so Go home and autopin can route there.")
            } else if model.location.lastKnown == nil {
                homeEntryPrompt("Waiting for your current location. You can still edit home.")
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private func homeEntryPrompt(_ text: String) -> some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Text(text)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.medium)
            Spacer(minLength: ChicagoSpacing.sm)
            Button {
                isHomeEntryPresented = true
            } label: {
                Label("Enter home", systemImage: "mappin.and.ellipse")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(ChicagoPalette.flagBlue)
        }
    }

    private func setGoHomeSelected(_ enabled: Bool) {
        goHomeSelected = enabled
        homePinStatusText = nil
        homePinStatusIsError = false
        if enabled {
            goHomeTapped()
        } else {
            homeTripOptions = []
            plannedTripPin = nil
            model.clearPlannedTripPin()
        }
    }

    private func goHomeTapped() {
        homePinStatusText = nil
        homePinStatusIsError = false
        guard commuteAnchors.home != nil else {
            isHomeEntryPresented = true
            return
        }
        planHomeRouteOptions()
    }

    private func planHomeRouteOptions() {
        guard let current = model.location.lastKnown else {
            homePinStatusText = "Waiting for your current location."
            homePinStatusIsError = true
            goHomeSelected = false
            return
        }
        guard let home = commuteAnchors.home else {
            isHomeEntryPresented = true
            return
        }

        isPinningHome = true
        homeTripOptions = []
        selectedHomeTripOptionId = nil
        selectedTrainChoiceId = nil
        selectedBusChoiceId = nil
        selectedMetraChoiceId = nil

        let origin = PlannerCoordinate(latitude: current.latitude, longitude: current.longitude)
        let destination = PlannerCoordinate(latitude: home.latitude, longitude: home.longitude)

        Task { @MainActor in
            do {
                let plans = try await tripPlanner.plan(from: origin, to: destination)
                guard !Task.isCancelled else { return }
                let options = buildHomeTripOptions(
                    from: plans,
                    origin: origin,
                    allowMultimodal: allowMultimodalHomePin
                )
                homeTripOptions = options
                selectedHomeTripOptionId = options.first?.id
                selectedTrainChoiceId = options.first?.trainChoices.first?.id
                selectedBusChoiceId = options.first?.busChoices.first?.id
                selectedMetraChoiceId = options.first?.metraChoices.first?.id
                homePinStatusText = options.isEmpty
                    ? "No pin-ready transit legs found for home."
                    : "Choose the route pieces to pin."
                homePinStatusIsError = options.isEmpty
                goHomeSelected = !options.isEmpty
                isPinningHome = false
            } catch {
                homePinStatusText = error.localizedDescription
                homePinStatusIsError = true
                goHomeSelected = false
                isPinningHome = false
            }
        }
    }

    private var homeTripOptionsCard: some View {
        ChicagoCard(title: "Trip home",
                    eyebrow: "Choose pin",
                    ornament: .icon(systemName: "point.topleft.down.curvedto.point.bottomright.up")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                ForEach(homeTripOptions) { option in
                    homeTripOptionRow(option)
                }
                Button {
                    pinSelectedHomeTrip()
                } label: {
                    Label("Pin selected trip", systemImage: "pin.fill")
                        .font(ChicagoTypography.displaySM(relativeTo: .callout))
                        .tracking(0.5)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ChicagoPalette.flagBlue)
                .disabled(selectedHomeTripOption == nil)
            }
        }
    }

    private func homeTripOptionRow(_ option: HomeTripOption) -> some View {
        let isSelected = selectedHomeTripOptionId == option.id
        return VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
            Button {
                selectedHomeTripOptionId = option.id
                selectedTrainChoiceId = option.trainChoices.first?.id
                selectedBusChoiceId = option.busChoices.first?.id
                selectedMetraChoiceId = option.metraChoices.first?.id
            } label: {
                HStack(spacing: ChicagoSpacing.sm) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? ChicagoPalette.flagBlue : ChicagoPalette.Gray.light)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                            .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                        Text("\(durationText(option.expectedTravelTime)) · \(option.transitSummary)")
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isSelected {
                if !option.trainChoices.isEmpty {
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        sectionLabel("Train")
                        StationChipStrip {
                            ForEach(option.trainChoices) { choice in
                                DirectionChip(
                                    label: choice.displayLabel,
                                    isSelected: selectedTrainChoiceId == choice.id,
                                    accent: choice.line.swiftUIColor,
                                    action: { selectedTrainChoiceId = choice.id }
                                )
                            }
                        }
                    }
                }

                if !option.busChoices.isEmpty {
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        sectionLabel("Bus boarding stop")
                        StationChipStrip {
                            ForEach(option.busChoices) { choice in
                                DirectionChip(
                                    label: choice.displayLabel,
                                    isSelected: selectedBusChoiceId == choice.id,
                                    accent: ChicagoPalette.flagBlue,
                                    action: { selectedBusChoiceId = choice.id }
                                )
                            }
                        }
                    }
                }

                if !option.metraChoices.isEmpty {
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        sectionLabel("Metra boarding station")
                        StationChipStrip {
                            ForEach(option.metraChoices) { choice in
                                DirectionChip(
                                    label: choice.displayLabel,
                                    isSelected: selectedMetraChoiceId == choice.id,
                                    accent: MetraStationCatalog.route(id: choice.routeId)?.swiftUIColor ?? ChicagoPalette.bahama,
                                    action: { selectedMetraChoiceId = choice.id }
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private func activeHomeTripCard(_ pin: PlannedTripPin) -> some View {
        ChicagoCard(title: pin.title,
                    eyebrow: "Trip pin",
                    ornament: .icon(systemName: "pin.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pin.summary.isEmpty ? "Planned route" : pin.summary)
                            .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                        Text(activeTripTimeText(pin))
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        goHomeSelected = false
                        plannedTripPin = nil
                        model.clearPlannedTripPin()
                    } label: {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let train = pin.train {
                    tripTrainRow(train)
                }
                if let bus = pin.bus {
                    tripBusRow(bus)
                }
                if let metra = pin.metra {
                    tripMetraRow(metra)
                }
            }
        }
    }

    private func tripTrainRow(_ train: PlannedTripPin.TrainLeg) -> some View {
        let arrivals = model.snapshot.trainArrivals
            .filter { $0.line == train.line }
            .filter { train.stationId == nil || $0.stationId == train.stationId }
            .filter { train.destinationName == nil || $0.destinationName == train.destinationName }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = arrivals.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(line: train.line, size: .sm)
                Text(train.stationName)
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Spacer()
            }
            if let minutes, let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next \(train.line.displayName) train"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                HeadwayDotStrip(arrivals: arrivals.prefix(8).map(\.arrivalAt),
                                accent: train.line.swiftUIColor)
            } else {
                Text(model.isRefreshing ? "Fetching arrivals…" : "No upcoming arrivals returned yet.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private func tripBusRow(_ bus: PlannedTripPin.BusLeg) -> some View {
        let predictions = model.snapshot.busPredictions
            .filter { $0.route == bus.route }
            .filter { bus.stopId == nil || $0.stopId == bus.stopId }
            .filter { bus.directionLabel == nil || $0.directionName == bus.directionLabel }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = predictions.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(bus: bus.route, size: .sm)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bus.stopName)
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    if let direction = bus.directionLabel, !direction.isEmpty {
                        Text(direction)
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    }
                }
                Spacer()
            }
            if let minutes, let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next Route \(bus.route) bus"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                HeadwayDotStrip(arrivals: predictions.prefix(8).map(\.arrivalAt),
                                accent: ChicagoPalette.flagBlue)
            } else {
                Text(model.isRefreshing ? "Fetching predictions…" : "No upcoming buses returned yet.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private func tripMetraRow(_ metra: PlannedTripPin.MetraLeg) -> some View {
        let predictions = model.snapshot.metraPredictions
            .filter { $0.routeId == metra.routeId }
            .filter { metra.stationId == nil || $0.stationId == metra.stationId }
            .filter { metra.directionId == nil || $0.directionId == metra.directionId }
            .filter { metra.destinationName == nil || $0.destinationName == metra.destinationName }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = predictions.first
        let accent = MetraStationCatalog.route(id: metra.routeId)?.swiftUIColor ?? ChicagoPalette.bahama
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(metra: metra.routeId, size: .sm)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metra.stationName)
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    if let destination = metra.destinationName, !destination.isEmpty {
                        Text("→ \(destination)")
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    }
                }
                Spacer()
            }
            if let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    MetraDepartureTimeView(
                        date: first.arrivalAt,
                        size: .md,
                        tone: first.isDelayed || first.isCanceled ? .alert : .primary,
                        accessibilityPrefix: "Next Metra train departs at"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                HeadwayDotStrip(arrivals: predictions.prefix(8).map(\.arrivalAt),
                                accent: accent)
            } else {
                Text(model.isRefreshing ? "Fetching Metra trains…" : "No upcoming Metra trains returned yet.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var selectedHomeTripOption: HomeTripOption? {
        guard let selectedHomeTripOptionId else { return nil }
        return homeTripOptions.first { $0.id == selectedHomeTripOptionId }
    }

    private func pinSelectedHomeTrip() {
        guard let option = selectedHomeTripOption else { return }
        let train = selectedTrainChoice(in: option).map {
            PlannedTripPin.TrainLeg(
                line: $0.line,
                stationId: $0.stationId,
                stationName: $0.stationName
            )
        }
        let bus = selectedBusChoice(in: option).map {
            PlannedTripPin.BusLeg(
                route: $0.route,
                stopId: $0.stopId,
                stopName: $0.stopName,
                directionLabel: $0.directionLabel
            )
        }
        let metra = selectedMetraChoice(in: option).map {
            PlannedTripPin.MetraLeg(
                routeId: $0.routeId,
                stationId: $0.stationId,
                stationName: $0.stationName,
                directionId: $0.directionId,
                destinationName: $0.destinationName
            )
        }
        guard train != nil || bus != nil || metra != nil else {
            homePinStatusText = "Pick at least one train, bus, or Metra leg."
            homePinStatusIsError = true
            return
        }
        let pin = PlannedTripPin(
            destination: .home,
            title: "Trip home",
            summary: option.transitSummary,
            expectedArrivalAt: Date().addingTimeInterval(option.expectedTravelTime),
            expectedTravelTime: option.expectedTravelTime,
            allowMultimodal: allowMultimodalHomePin,
            train: train,
            bus: bus,
            metra: metra
        )
        plannedTripPin = pin
        homeTripOptions = []
        homePinStatusText = nil
        homePinStatusIsError = false
        goHomeSelected = true
        model.savePlannedTripPin(pin)
    }

    private func selectedTrainChoice(in option: HomeTripOption) -> HomeTripTrainChoice? {
        guard !option.trainChoices.isEmpty else { return nil }
        if let selectedTrainChoiceId,
           let choice = option.trainChoices.first(where: { $0.id == selectedTrainChoiceId })
        {
            return choice
        }
        return option.trainChoices.first
    }

    private func selectedBusChoice(in option: HomeTripOption) -> HomeTripBusChoice? {
        guard !option.busChoices.isEmpty else { return nil }
        if let selectedBusChoiceId,
           let choice = option.busChoices.first(where: { $0.id == selectedBusChoiceId })
        {
            return choice
        }
        return option.busChoices.first
    }

    private func selectedMetraChoice(in option: HomeTripOption) -> HomeTripMetraChoice? {
        guard !option.metraChoices.isEmpty else { return nil }
        if let selectedMetraChoiceId,
           let choice = option.metraChoices.first(where: { $0.id == selectedMetraChoiceId })
        {
            return choice
        }
        return option.metraChoices.first
    }

    private func buildHomeTripOptions(
        from plans: [TripPlan],
        origin: PlannerCoordinate,
        allowMultimodal: Bool
    ) -> [HomeTripOption] {
        plans.compactMap { plan -> HomeTripOption? in
            let transitLegs = plan.legs.enumerated().filter { $0.element.mode == .transit }
            guard !transitLegs.isEmpty else { return nil }
            guard allowMultimodal || transitLegs.count == 1 else { return nil }

            var trainChoices: [HomeTripTrainChoice] = []
            var busChoices: [HomeTripBusChoice] = []
            var metraChoices: [HomeTripMetraChoice] = []

            for (index, leg) in transitLegs {
                guard let resolution = leg.transit?.resolution else { continue }
                switch resolution {
                case .line(let line):
                    trainChoices.append(contentsOf: trainChoicesForHomeTrip(
                        line: line,
                        legIndex: index,
                        leg: leg,
                        fallbackOrigin: origin
                    ))
                case .bus(let route):
                    busChoices.append(contentsOf: busChoicesForHomeTrip(
                        route: route,
                        legIndex: index,
                        leg: leg,
                        fallbackOrigin: origin
                    ))
                case .metra(let route):
                    metraChoices.append(contentsOf: metraChoicesForHomeTrip(
                        route: route,
                        legIndex: index,
                        leg: leg,
                        fallbackOrigin: origin
                    ))
                case .unknown:
                    continue
                }
            }

            let dedupedTrains = dedupeTrainChoices(trainChoices)
            let dedupedBuses = dedupeBusChoices(busChoices)
            let dedupedMetra = dedupeMetraChoices(metraChoices)
            guard !dedupedTrains.isEmpty || !dedupedBuses.isEmpty || !dedupedMetra.isEmpty else { return nil }

            return HomeTripOption(
                title: homeTripTitle(plan: plan, transitLegCount: transitLegs.count),
                transitSummary: homeTripTransitSummary(
                    trains: dedupedTrains,
                    buses: dedupedBuses,
                    metras: dedupedMetra
                ),
                expectedTravelTime: plan.expectedTravelTime,
                totalDistanceMeters: plan.totalDistanceMeters,
                trainChoices: dedupedTrains,
                busChoices: dedupedBuses,
                metraChoices: dedupedMetra
            )
        }
    }

    private func trainChoicesForHomeTrip(
        line: LineColor,
        legIndex: Int,
        leg: TripLeg,
        fallbackOrigin: PlannerCoordinate
    ) -> [HomeTripTrainChoice] {
        let point = leg.startCoordinate ?? fallbackOrigin
        let candidates = NearestStationResolver(maxDistanceMeters: 1_500)
            .closestStations(
                onLine: line,
                to: (point.latitude, point.longitude),
                limit: 3,
                catalog: LStationCatalog.all,
                excludingStationIds: closedStationIds
            )
        return candidates.map { entry in
            HomeTripTrainChoice(
                line: line,
                stationId: entry.station.id,
                stationName: entry.station.name,
                distanceMeters: entry.distance,
                legIndex: legIndex
            )
        }
    }

    private func busChoicesForHomeTrip(
        route: String,
        legIndex: Int,
        leg: TripLeg,
        fallbackOrigin: PlannerCoordinate
    ) -> [HomeTripBusChoice] {
        let point = leg.startCoordinate ?? fallbackOrigin
        let resolver = NearestBusStopResolver(maxDistanceMeters: 1_500)
        let candidates = resolver.nearestStopsPerDirection(
            onRoute: route,
            to: (point.latitude, point.longitude),
            limitPerDirection: 3,
            catalog: BusStopCatalog.all
        )
        return candidates.map { entry in
            HomeTripBusChoice(
                route: route,
                stopId: entry.stop.id,
                stopName: entry.stop.name,
                directionLabel: entry.stop.directionLabel,
                distanceMeters: entry.distance,
                legIndex: legIndex
            )
        }
    }

    private func metraChoicesForHomeTrip(
        route: String,
        legIndex: Int,
        leg: TripLeg,
        fallbackOrigin: PlannerCoordinate
    ) -> [HomeTripMetraChoice] {
        let point = leg.startCoordinate ?? fallbackOrigin
        let resolver = NearestMetraStationResolver(maxDistanceMeters: 3_000)
        let candidates = resolver.closestStations(
            onRoute: route,
            to: (point.latitude, point.longitude),
            limit: 3,
            catalog: MetraStationCatalog.all
        )
        return candidates.map { entry in
            HomeTripMetraChoice(
                routeId: route,
                stationId: entry.station.id,
                stationName: entry.station.name,
                directionId: nil,
                destinationName: nil,
                distanceMeters: entry.distance,
                legIndex: legIndex
            )
        }
    }

    private func dedupeTrainChoices(_ choices: [HomeTripTrainChoice]) -> [HomeTripTrainChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert($0.id).inserted }
    }

    private func dedupeBusChoices(_ choices: [HomeTripBusChoice]) -> [HomeTripBusChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert($0.id).inserted }
    }

    private func dedupeMetraChoices(_ choices: [HomeTripMetraChoice]) -> [HomeTripMetraChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert($0.id).inserted }
    }

    private func homeTripTitle(plan: TripPlan, transitLegCount: Int) -> String {
        if plan.flavor == .standard, !plan.summary.isEmpty {
            return plan.summary
        }
        if transitLegCount > 1 {
            return "Multimodal route"
        }
        switch plan.flavor {
        case .train: return "Train route"
        case .metra: return "Metra route"
        case .busShortestRide: return "Bus route"
        case .busShortestWalk: return "Low-walk bus route"
        case .standard: return "Transit route"
        }
    }

    private func homeTripTransitSummary(
        trains: [HomeTripTrainChoice],
        buses: [HomeTripBusChoice],
        metras: [HomeTripMetraChoice]
    ) -> String {
        let trainPieces = trains.map { $0.line.displayName }
        let busPieces = buses.map { "Route \($0.route)" }
        let metraPieces = metras.map { MetraStationCatalog.route(id: $0.routeId)?.shortName ?? $0.routeId }
        let pieces = Array((trainPieces + busPieces + metraPieces.map { "Metra \($0)" }).prefix(3))
        return pieces.isEmpty ? "Transit" : pieces.joined(separator: " + ")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    private func activeTripTimeText(_ pin: PlannedTripPin) -> String {
        guard let arrival = pin.expectedArrivalAt else {
            return durationText(pin.expectedTravelTime)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(durationText(pin.expectedTravelTime)) · arrives \(formatter.string(from: arrival))"
    }

    // MARK: - Trip planner

    private var tripPlannerCard: some View {
        Button {
            isTripPlannerPresented = true
        } label: {
            HStack(spacing: ChicagoSpacing.md) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(ChicagoPalette.flagBlue,
                                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan a trip")
                        .font(ChicagoTypography.displayMD(relativeTo: .headline))
                        .tracking(0.5)
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    Text("Search a destination and let Apple Maps pick the legs.")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: ChicagoSpacing.sm)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
            .padding(ChicagoSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChicagoPalette.Surface.card,
                        in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.lg)
                    .strokeBorder(ChicagoPalette.cornflower.opacity(0.35),
                                  lineWidth: ChicagoSpacing.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live updates toggle

    private var liveUpdatesBar: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Circle()
                .fill(liveStatusDotColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.liveUpdatesActive ? "Live updates on" : "Live updates off")
                    .font(ChicagoTypography.displaySM(relativeTo: .footnote))
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Text(liveStatusDescription)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            Spacer()
            Toggle("Live updates", isOn: Binding(
                get: { model.liveUpdatesEnabled },
                set: { model.setLiveUpdatesEnabled($0) }
            ))
            .labelsHidden()
            .tint(ChicagoPalette.flagBlue)
            .disabled(model.isLowPowerMode)
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var liveStatusDotColor: Color {
        if model.isLowPowerMode { return ChicagoPalette.gold }
        return model.liveUpdatesEnabled ? ChicagoPalette.green : ChicagoPalette.Gray.light
    }

    private var liveStatusDescription: String {
        if model.isLowPowerMode {
            return "Low Power Mode is on — auto-refresh paused"
        }
        if model.liveUpdatesEnabled {
            return "Polling CTA and Metra every 30 seconds for fresh delays"
        }
        return "Pull to refresh, or wait for background updates"
    }

    // MARK: - Context banner

    private var contextBanner: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Image(systemName: autoPinnedDirection == .toHome ? "house.fill" : "sparkles")
                .foregroundStyle(ChicagoPalette.flagBlue)
            Text(autopinDescription)
                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
            Text("Autopin")
                .font(ChicagoTypography.displaySM(relativeTo: .caption2))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, ChicagoSpacing.sm)
                .padding(.vertical, 3)
                .background(ChicagoPalette.flagBlue,
                            in: Capsule())
            Spacer()
            if model.isRefreshing { ProgressView().scaleEffect(0.7) }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.lakeMichigan,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var shouldShowAutopinBanner: Bool {
        isAutopinned
    }

    private var autopinDescription: String {
        switch autoPinnedDirection {
        case .toHome:
            return "Auto-pin is surfacing the route home."
        case .toWork:
            return "Auto-pin is surfacing the route to work."
        case .anytime, nil:
            return "Auto-pin is surfacing a commute route."
        }
    }

    private var isAutopinned: Bool {
        pinSource == .automatic && (pinnedLine != nil || pinnedBusRoute != nil || pinnedMetraRoute != nil)
    }

    // MARK: - Train line picker

    private var linePickerCard: some View {
        ChicagoCard(title: "Pin an L line",
                    eyebrow: "Trains",
                    ornament: .icon(systemName: "tram.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ForEach(LineColor.allCases, id: \.self) { line in
                            LineChip(
                                line: line,
                                isPinned: pinnedLine == line,
                                action: { togglePinnedLine(line) }
                            )
                        }
                    }
                }
                Text(pinnedLine == nil
                     ? "Tap a line to surface its nearest station and route it to the Live Activity."
                     : "Tap again to unpin.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
    }

    private func pinnedLineCard(line: LineColor) -> some View {
        ChicagoCard(title: line.displayName,
                    eyebrow: isAutopinned ? "Autopinned line" : "Pinned line",
                    ornament: .icon(systemName: "tram.fill")) {
            pinnedLineBody(line: line)
        }
    }

    @ViewBuilder
    private func pinnedLineBody(line: LineColor) -> some View {
        if let origin {
            // Pull a wider candidate pool than the minimum display count so
            // walking-aware re-ranking and the tie band can surface downtown
            // alternatives that MapKit might otherwise bury.
            let candidates = NearestStationResolver(maxDistanceMeters: 10_000)
                .closestStations(
                    onLine: line,
                    to: origin,
                    limit: 12,
                    catalog: LStationCatalog.all,
                    excludingStationIds: closedStationIds
                )

            if candidates.isEmpty {
                Text("No \(line.displayName) station within 10 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                let ranked = rankWithWalking(candidates: candidates, origin: origin)
                let stations = StationAccessRanker().visibleCandidates(from: ranked)
                let hasWalkingData = stations.contains { $0.walkingDistanceMeters != nil }
                let chosenId = effectivePinnedStation(stations: stations)
                VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                    sectionLabel("Pick a stop")
                    if hasWalkingData || allowHaversineFallback {
                        StationChipStrip {
                            ForEach(stations, id: \.station.id) { entry in
                                StationChip(
                                    station: entry.station,
                                    travelTime: entry.displayTravelTime,
                                    isApproximateTravelTime: entry.isApproximateTravelTime,
                                    isSelected: entry.station.id == chosenId,
                                    accent: line.swiftUIColor,
                                    action: { setPinnedStation(entry.station.id) }
                                )
                            }
                        }
                        if let chosen = stations.first(where: { $0.station.id == chosenId }) {
                            directionPickerForTrain(at: chosen.station, line: line)
                            arrivalsHeadline(at: chosen.station, line: line)
                            trainProgressStrip(toStation: chosen.station, line: line)
                        }
                    } else {
                        placeholderChipStrip
                        // Keep arrivals visible for a user whose pin is
                        // already sticky from a previous session — we
                        // don't know the new ranking yet, but we do know
                        // their station.
                        if let pinnedId = pinnedStationId,
                           let stuck = candidates.first(where: { $0.station.id == pinnedId })?.station
                        {
                            directionPickerForTrain(at: stuck, line: line)
                            arrivalsHeadline(at: stuck, line: line)
                            trainProgressStrip(toStation: stuck, line: line)
                        }
                    }
                }
                .task(id: walkingTaskKey(line: line, origin: origin)) {
                    allowHaversineFallback = false
                    model.walkingResolver.ensureFresh(
                        origin: origin,
                        stations: candidates.map(\.station)
                    )
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        allowHaversineFallback = true
                    } catch {
                        // Cancelled — origin or line changed, next .task
                        // run will reset the flag.
                    }
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    /// Re-ranks candidates by walking distance where MapKit has answered,
    /// with a directness proxy to keep obviously inflated routes from hiding
    /// comparable stops. The view layer renders shimmer placeholders briefly
    /// when *no* candidate has walking data, so the user doesn't see a stale
    /// ordering for the ~300ms before MapKit responds at a new location.
    private func rankWithWalking(
        candidates: [(station: LStation, distance: Double)],
        origin: (lat: Double, lon: Double)
    ) -> [StationAccessRanker.RankedCandidate] {
        let walkingResolver = model.walkingResolver
        let ranker = StationAccessRanker()
        return ranker.rank(
            candidates.map { entry in
                let walking = walkingResolver.cached(
                    origin: origin,
                    stationId: entry.station.id
                ) ?? walkingResolver.staleFallback(
                    origin: origin,
                    stationId: entry.station.id
                )
                return StationAccessRanker.Candidate(
                    station: entry.station,
                    directDistanceMeters: entry.distance,
                    walkingDistanceMeters: walking?.meters,
                    walkingTravelTime: walking?.expectedTravelTime
                )
            }
        )
    }

    private func walkingTaskKey(line: LineColor, origin: (lat: Double, lon: Double)) -> String {
        // ~10m grid: enough precision to retrigger when the user actually
        // moves, coarse enough to avoid GPS-jitter thrashes mid-render.
        let lat = (origin.lat * 11000).rounded()
        let lon = (origin.lon * 11000).rounded()
        return "\(line.rawValue):\(lat):\(lon)"
    }

    private var placeholderChipStrip: some View {
        StationChipStrip {
            ForEach(0..<3, id: \.self) { _ in
                StationChipPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func directionPickerForTrain(at station: LStation, line: LineColor) -> some View {
        let destinations = Array(Set(
            model.snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == station.id }
                .map(\.destinationName)
        )).sorted()
        if destinations.count > 1 {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Pick a direction")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ForEach(destinations, id: \.self) { dest in
                            DirectionChip(
                                label: "→ \(dest)",
                                isSelected: pinnedTrainDestination == dest,
                                accent: line.swiftUIColor,
                                action: { togglePinnedTrainDestination(dest) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// **The dashboard's headline visualisation.** A massive `BigNumber`
    /// for the next arrival, then a `HeadwayDotStrip` showing the next
    /// ~30 minutes of arrivals as dots positioned by time. Bunching is
    /// visible without reading a single number.
    @ViewBuilder
    private func arrivalsHeadline(at station: LStation, line: LineColor) -> some View {
        let arrivals: [Arrival] = {
            let base = model.snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == station.id }
                .sorted { $0.arrivalAt < $1.arrivalAt }
            if let pinned = pinnedTrainDestination {
                return base.filter { $0.destinationName == pinned }
            }
            return base
        }()

        if arrivals.isEmpty {
            Text(model.isRefreshing
                 ? "Fetching arrivals…"
                 : "No upcoming \(line.displayName) arrivals returned by CTA.")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        } else {
            let grouped = Dictionary(grouping: arrivals, by: \.destinationName)
                .sorted { ($0.value.first?.arrivalAt ?? .distantFuture)
                          < ($1.value.first?.arrivalAt ?? .distantFuture) }
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                ForEach(grouped, id: \.key) { dest, times in
                    let first = times.first!
                    let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        Text("→ \(dest)")
                            .font(ChicagoTypography.displaySM(relativeTo: .caption))
                            .tracking(0.5)
                            .foregroundStyle(ChicagoPalette.bahama)
                        HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                            BigNumber(
                                minutes,
                                unit: "min",
                                size: .lg,
                                tone: first.isDelayed ? .alert : .primary,
                                accessibilityLabel: "\(minutes) minutes to next \(dest) train"
                            )
                            if first.isDelayed {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(ChicagoPalette.starRed)
                                    .accessibilityLabel("Delayed")
                            }
                        }
                        HeadwayDotStrip(
                            arrivals: times.prefix(8).map(\.arrivalAt),
                            accent: line.swiftUIColor
                        )
                    }
                }
            }
        }
    }

    private func effectivePinnedStation(
        stations: [StationAccessRanker.RankedCandidate]
    ) -> Int {
        if let id = pinnedStationId,
           stations.contains(where: { $0.station.id == id })
        {
            return id
        }
        return stations.first?.station.id ?? 0
    }

    private func togglePinnedLine(_ line: LineColor) {
        let newValue: LineColor? = (pinnedLine == line) ? nil : line
        pinnedLine = newValue
        pinnedStationId = nil
        pinnedTrainDestination = nil
        model.saveManualRoutePreferences {
            $0.pinnedLine = newValue
            $0.pinnedStationId = nil
            $0.pinnedTrainDestination = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedStation(_ id: Int) {
        pinnedStationId = id
        pinnedTrainDestination = nil
        model.saveManualRoutePreferences {
            $0.pinnedStationId = id
            $0.pinnedTrainDestination = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    /// Live-position strip — locks onto the *specific* train that's predicted
    /// to arrive next at the selected station (by run number) so the strip
    /// and the headline number always describe the same vehicle.
    @ViewBuilder
    private func trainProgressStrip(toStation station: LStation, line: LineColor) -> some View {
        let stationCoord = (lat: station.latitude, lon: station.longitude)
        let stationArrivals = model.snapshot.trainArrivals
            .filter { $0.line == line && $0.stationId == station.id }
        let pinnedArrival = stationArrivals
            .filter { pinnedTrainDestination == nil || $0.destinationName == pinnedTrainDestination }
            .min(by: { $0.arrivalAt < $1.arrivalAt })
        let arrivingDestinations = Set(stationArrivals.map(\.destinationName))

        let candidates: [(VehiclePosition, Double)] = {
            if let runId = pinnedArrival?.runNumber,
               let exact = model.vehiclePositions
                .first(where: { $0.id == runId && $0.mode == .train })
            {
                return [(exact, Distance.meters(from: stationCoord, to: (exact.latitude, exact.longitude)))]
            }
            return model.vehiclePositions
                .filter { $0.mode == .train && $0.route == line.rawValue }
                .filter { vehicle in
                    let constraint: Set<String> = {
                        if let pinned = pinnedTrainDestination { return [pinned] }
                        return arrivingDestinations
                    }()
                    guard !constraint.isEmpty else { return true }
                    guard let dest = vehicle.destinationName else { return false }
                    return constraint.contains(dest)
                }
                .map { ($0, Distance.meters(from: stationCoord, to: ($0.latitude, $0.longitude))) }
                .sorted { $0.1 < $1.1 }
        }()
        if let closest = candidates.first {
            let vehicleCoord = (lat: closest.0.latitude, lon: closest.0.longitude)
            let intermediate = intermediateStops(
                vehicle: vehicleCoord,
                userStop: stationCoord,
                candidates: LStationCatalog.all
                    .filter { $0.servedLines.contains(line) && $0.id != station.id }
                    .map { ($0.name, $0.latitude, $0.longitude) },
                limit: 4
            )
            MareyProgressStrip(
                distanceMeters: closest.1,
                scaleMeters: max(closest.1, 1_500),
                accent: line.swiftUIColor,
                vehicleLabel: closest.0.destinationName.map { "→ \($0)" } ?? "Train",
                stopLabel: station.name,
                intermediateStops: intermediate
            )
        }
    }

    /// Bus version.
    @ViewBuilder
    private func busProgressStrip(toStop stop: BusStop, route: String) -> some View {
        let stopCoord = (lat: stop.latitude, lon: stop.longitude)
        let stopPredictions = model.snapshot.busPredictions
            .filter { $0.route == route && $0.stopId == stop.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let nextVid = stopPredictions.first?.vehicleId
        let arrivingDestinations = Set(stopPredictions.map(\.destinationName))

        let candidates: [(VehiclePosition, Double)] = {
            if let vid = nextVid,
               let exact = model.vehiclePositions
                .first(where: { $0.id == vid && $0.mode == .bus })
            {
                return [(exact, Distance.meters(from: stopCoord, to: (exact.latitude, exact.longitude)))]
            }
            return model.vehiclePositions
                .filter { $0.mode == .bus && $0.route == route }
                .filter { vehicle in
                    guard !arrivingDestinations.isEmpty else { return true }
                    guard let dest = vehicle.destinationName else { return false }
                    return arrivingDestinations.contains(dest)
                }
                .map { ($0, Distance.meters(from: stopCoord, to: ($0.latitude, $0.longitude))) }
                .sorted { $0.1 < $1.1 }
        }()
        if let closest = candidates.first {
            let vehicleCoord = (lat: closest.0.latitude, lon: closest.0.longitude)
            let routeStops = BusStopCatalog.all
                .filter { $0.route == route
                          && $0.directionLabel == stop.directionLabel
                          && $0.id != stop.id }
                .map { ($0.name, $0.latitude, $0.longitude) }
            let intermediate = intermediateStops(
                vehicle: vehicleCoord,
                userStop: stopCoord,
                candidates: routeStops,
                limit: 4
            )
            MareyProgressStrip(
                distanceMeters: closest.1,
                scaleMeters: max(closest.1, 1_500),
                accent: ChicagoPalette.flagBlue,
                vehicleLabel: closest.0.destinationName.map { "→ \($0)" } ?? "Bus",
                stopLabel: stop.directionLabel.isEmpty ? stop.name : stop.directionLabel,
                intermediateStops: intermediate
            )
        }
    }

    /// Stops on the route that lie *between* the vehicle and the user's stop,
    /// projected onto the V→U axis so order matches travel direction even
    /// when the route curves.
    private func intermediateStops(
        vehicle: (lat: Double, lon: Double),
        userStop: (lat: Double, lon: Double),
        candidates: [(name: String, lat: Double, lon: Double)],
        limit: Int? = nil
    ) -> [RouteStop] {
        let total = Distance.meters(from: vehicle, to: userStop)
        guard total > 50 else { return [] }

        let dLat = userStop.lat - vehicle.lat
        let dLon = userStop.lon - vehicle.lon
        let normSq = dLat * dLat + dLon * dLon
        guard normSq > 0 else { return [] }

        let tolerance = max(300.0, total * 0.20)

        let ticks: [RouteStop] = candidates.compactMap { stop in
            let dVehicle = Distance.meters(from: vehicle, to: (stop.lat, stop.lon))
            let dUser    = Distance.meters(from: userStop, to: (stop.lat, stop.lon))
            guard dVehicle < total, dUser < total else { return nil }
            guard dVehicle + dUser <= total + tolerance else { return nil }

            let sdLat = stop.lat - vehicle.lat
            let sdLon = stop.lon - vehicle.lon
            let dot = sdLat * dLat + sdLon * dLon
            let projection = max(0, min(1, dot / normSq))
            return RouteStop(label: stop.name, fraction: projection)
        }

        let sorted = ticks.sorted { $0.fraction < $1.fraction }
        if let limit, sorted.count > limit {
            return Array(sorted.suffix(limit))
        }
        return sorted
    }

    private func togglePinnedTrainDestination(_ destination: String) {
        let newValue: String? = (pinnedTrainDestination == destination) ? nil : destination
        pinnedTrainDestination = newValue
        model.saveManualRoutePreferences {
            $0.pinnedTrainDestination = newValue
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bus route picker

    private var busRoutePickerCard: some View {
        ChicagoCard(title: "Pin a bus route",
                    eyebrow: "Buses",
                    ornament: .icon(systemName: "bus.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                Menu {
                    if pinnedBusRoute != nil {
                        Button("Unpin", role: .destructive) { setPinnedBus(nil) }
                        Divider()
                    }
                    ForEach(BusStopCatalog.allRoutes, id: \.self) { route in
                        Button("Route \(route)") { setPinnedBus(route) }
                    }
                } label: {
                    HStack(spacing: ChicagoSpacing.xs) {
                        Image(systemName: "bus.fill")
                            .foregroundStyle(ChicagoPalette.flagBlue)
                        Text(pinnedBusRoute.map { "Route \($0)" } ?? "Choose a route")
                            .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(ChicagoPalette.Gray.light)
                    }
                    .padding(.horizontal, ChicagoSpacing.md)
                    .padding(.vertical, ChicagoSpacing.sm)
                    .background(ChicagoPalette.Surface.elevated,
                                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
                }
                Text("Manual pins pause autopin for 30 minutes.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
    }

    private func pinnedBusCard(route: String) -> some View {
        ChicagoCard(title: "Route \(route)",
                    eyebrow: isAutopinned ? "Autopinned bus" : "Pinned bus",
                    ornament: .icon(systemName: "bus.fill")) {
            pinnedBusBody(route: route)
        }
    }

    @ViewBuilder
    private func pinnedBusBody(route: String) -> some View {
        if let origin {
            let directionChoices = busStopChoices(route: route, origin: origin)
            if directionChoices.isEmpty {
                Text("No Route \(route) stop within 5 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if directionChoices.count > 1 {
                        directionPickerForBus(choices: directionChoices)
                    }
                    let visibleDirections: [BusDirectionStopChoice] = {
                        guard let pinned = pinnedBusDirection else { return directionChoices }
                        let filtered = directionChoices.filter { $0.directionLabel == pinned }
                        return filtered.isEmpty ? directionChoices : filtered
                    }()
                    ForEach(visibleDirections) { choice in
                        let selected = effectivePinnedBusStop(in: choice)
                        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                            if choice.stops.count > 1 {
                                busStopSelector(choice: choice)
                            }
                            pinnedBusDirectionRow(route: route, stop: selected.stop, origin: origin)
                        }
                    }
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    @ViewBuilder
    private func directionPickerForBus(choices: [BusDirectionStopChoice]) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a direction")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ChicagoSpacing.xs) {
                    ForEach(choices) { choice in
                        DirectionChip(
                            label: choice.displayLabel,
                            isSelected: pinnedBusDirection == choice.directionLabel,
                            accent: ChicagoPalette.flagBlue,
                            action: { togglePinnedBusDirection(choice.directionLabel) }
                        )
                    }
                }
            }
        }
    }

    private func busStopChoices(
        route: String,
        origin: (lat: Double, lon: Double)
    ) -> [BusDirectionStopChoice] {
        let ranked = NearestBusStopResolver(maxDistanceMeters: 5_000)
            .nearestStopsPerDirection(
                onRoute: route,
                to: origin,
                limitPerDirection: 2,
                catalog: BusStopCatalog.all
            )
        let grouped = Dictionary(grouping: ranked, by: { $0.stop.directionLabel })
        return grouped.values.compactMap { entries -> BusDirectionStopChoice? in
            let stops = entries
                .sorted { $0.distance < $1.distance }
                .map { BusStopChoice(stop: $0.stop, distance: $0.distance) }
            guard let first = stops.first else { return nil }
            return BusDirectionStopChoice(
                directionLabel: first.stop.directionLabel,
                stops: stops
            )
        }
        .sorted {
            ($0.stops.first?.distance ?? .infinity) < ($1.stops.first?.distance ?? .infinity)
        }
    }

    private func busStopSelector(choice: BusDirectionStopChoice) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a stop")
            StationChipStrip {
                ForEach(choice.stops) { entry in
                    BusStopChip(
                        stop: entry.stop,
                        distance: entry.distance,
                        isSelected: entry.stop.id == effectivePinnedBusStop(in: choice).stop.id,
                        accent: ChicagoPalette.flagBlue,
                        action: { setPinnedBusStop(entry.stop) }
                    )
                }
            }
        }
    }

    private func effectivePinnedBusStop(
        in choice: BusDirectionStopChoice
    ) -> BusStopChoice {
        if let id = pinnedBusStopId,
           let selected = choice.stops.first(where: { $0.stop.id == id })
        {
            return selected
        }
        return choice.stops.first!
    }

    private func pinnedBusDirectionRow(
        route: String,
        stop: BusStop,
        origin: (lat: Double, lon: Double)
    ) -> some View {
        let distance = Distance.meters(
            from: origin,
            to: (stop.latitude, stop.longitude)
        )
        let predictions = model.snapshot.busPredictions
            .filter { $0.route == route && $0.stopId == stop.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = predictions.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(stop.directionLabel.isEmpty ? stop.name : stop.directionLabel)
                    .font(ChicagoTypography.displaySM(relativeTo: .footnote))
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.bahama)
                Spacer()
                Text(WalkTimeFormatter.short(distanceMeters: distance))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            Text(stop.name)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.light)
            if predictions.isEmpty {
                Text(model.isRefreshing
                     ? "Fetching predictions…"
                     : "No upcoming buses returned by CTA.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else if let minutes, let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next bus"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                HeadwayDotStrip(
                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                    accent: ChicagoPalette.flagBlue
                )
            }
            busProgressStrip(toStop: stop, route: route)
        }
    }

    private func setPinnedBus(_ route: String?) {
        pinnedBusRoute = route
        pinnedBusDirection = nil
        pinnedBusStopId = nil
        model.saveManualRoutePreferences {
            $0.pinnedBusRoute = route
            $0.pinnedBusDirection = nil
            $0.pinnedBusStopId = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func togglePinnedBusDirection(_ direction: String) {
        let newValue: String? = (pinnedBusDirection == direction) ? nil : direction
        pinnedBusDirection = newValue
        pinnedBusStopId = nil
        model.saveManualRoutePreferences {
            $0.pinnedBusDirection = newValue
            $0.pinnedBusStopId = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedBusStop(_ stop: BusStop) {
        pinnedBusRoute = stop.route
        pinnedBusDirection = stop.directionLabel
        pinnedBusStopId = stop.id
        model.saveManualRoutePreferences {
            $0.pinnedBusRoute = stop.route
            $0.pinnedBusDirection = stop.directionLabel
            $0.pinnedBusStopId = stop.id
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Metra route picker

    private var metraRoutePickerCard: some View {
        ChicagoCard(title: "Pin a Metra line",
                    eyebrow: "Metra",
                    ornament: .icon(systemName: "train.side.front.car")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                Menu {
                    if pinnedMetraRoute != nil {
                        Button("Unpin", role: .destructive) { setPinnedMetra(nil) }
                        Divider()
                    }
                    ForEach(MetraStationCatalog.routes, id: \.id) { line in
                        Button(line.displayName) { setPinnedMetra(line.id) }
                    }
                } label: {
                    HStack(spacing: ChicagoSpacing.xs) {
                        Image(systemName: "train.side.front.car")
                            .foregroundStyle(ChicagoPalette.flagBlue)
                        Text(pinnedMetraRoute.map { MetraStationCatalog.route(id: $0)?.displayName ?? $0 } ?? "Choose a line")
                            .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                            .foregroundStyle(ChicagoPalette.Gray.darkest)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(ChicagoPalette.Gray.light)
                    }
                    .padding(.horizontal, ChicagoSpacing.md)
                    .padding(.vertical, ChicagoSpacing.sm)
                    .background(ChicagoPalette.Surface.elevated,
                                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
                }
                Text("Uses Metra’s GTFS schedule, then overlays realtime updates when your Metra key is set.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
    }

    private func pinnedMetraCard(route: String) -> some View {
        let line = MetraStationCatalog.route(id: route)
        return ChicagoCard(title: line?.displayName ?? route,
                           eyebrow: isAutopinned ? "Autopinned Metra" : "Pinned Metra",
                           ornament: .icon(systemName: "train.side.front.car")) {
            pinnedMetraBody(route: route)
        }
    }

    @ViewBuilder
    private func pinnedMetraBody(route: String) -> some View {
        if let origin {
            let choices = metraStationChoices(route: route, origin: origin)
            if choices.isEmpty {
                Text("No \(route) station within 20 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                let selected = effectivePinnedMetraStation(in: choices)
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    metraStationSelector(choices: choices)
                    directionPickerForMetra(route: route, station: selected.station)
                    pinnedMetraStationRow(route: route, station: selected.station, origin: origin)
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    private func metraStationChoices(
        route: String,
        origin: (lat: Double, lon: Double)
    ) -> [MetraStationChoice] {
        NearestMetraStationResolver(maxDistanceMeters: 20_000)
            .closestStations(
                onRoute: route,
                to: origin,
                limit: 6,
                catalog: MetraStationCatalog.all
            )
            .map { MetraStationChoice(station: $0.station, distance: $0.distance) }
    }

    private func metraStationSelector(choices: [MetraStationChoice]) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a station")
            StationChipStrip {
                ForEach(choices) { entry in
                    MetraStationChip(
                        station: entry.station,
                        distance: entry.distance,
                        isSelected: entry.station.id == effectivePinnedMetraStation(in: choices).station.id,
                        accent: pinnedMetraAccent,
                        action: { setPinnedMetraStation(entry.station) }
                    )
                }
            }
        }
    }

    private func effectivePinnedMetraStation(
        in choices: [MetraStationChoice]
    ) -> MetraStationChoice {
        if let id = pinnedMetraStationId,
           let selected = choices.first(where: { $0.station.id == id })
        {
            return selected
        }
        return choices.first!
    }

    @ViewBuilder
    private func directionPickerForMetra(route: String, station: MetraStation) -> some View {
        let choices = MetraStationCatalog.directionChoices(routeId: route, stationId: station.id)
        if choices.count > 1 {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Pick a direction")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ForEach(choices) { choice in
                            DirectionChip(
                                label: choice.label,
                                isSelected: pinnedMetraDirectionId == choice.directionId
                                    && pinnedMetraDestination == choice.destinationName,
                                accent: pinnedMetraAccent,
                                action: { togglePinnedMetraDirection(choice) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func pinnedMetraStationRow(
        route: String,
        station: MetraStation,
        origin: (lat: Double, lon: Double)
    ) -> some View {
        let distance = Distance.meters(
            from: origin,
            to: (station.latitude, station.longitude)
        )
        let predictions = metraPredictions(route: route, station: station)
        let first = predictions.first
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(station.name)
                    .font(ChicagoTypography.displaySM(relativeTo: .footnote))
                    .tracking(0.5)
                    .foregroundStyle(ChicagoPalette.bahama)
                Spacer()
                Text(WalkTimeFormatter.short(distanceMeters: distance))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            if let zone = station.zoneId {
                Text("Zone \(zone)")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
            if predictions.isEmpty {
                Text(model.isRefreshing
                     ? "Fetching Metra trains…"
                     : "No upcoming Metra trains in the schedule window.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else if let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    MetraDepartureTimeView(
                        date: first.arrivalAt,
                        size: .md,
                        tone: first.isDelayed || first.isCanceled ? .alert : .primary,
                        accessibilityPrefix: "Next Metra train departs at"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                HeadwayDotStrip(
                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                    accent: pinnedMetraAccent
                )
            }
            metraProgressStrip(toStation: station, route: route)
        }
    }

    private func metraPredictions(route: String, station: MetraStation) -> [MetraPrediction] {
        model.snapshot.metraPredictions
            .filter { prediction in
                guard prediction.routeId == route, prediction.stationId == station.id else { return false }
                if let directionId = pinnedMetraDirectionId,
                   prediction.directionId != directionId {
                    return false
                }
                if let destination = pinnedMetraDestination,
                   prediction.destinationName != destination {
                    return false
                }
                return true
            }
            .sorted { $0.arrivalAt < $1.arrivalAt }
    }

    @ViewBuilder
    private func metraProgressStrip(toStation station: MetraStation, route: String) -> some View {
        let stationCoord = (lat: station.latitude, lon: station.longitude)
        let candidates = model.vehiclePositions
            .filter { $0.mode == .metra && $0.route == route }
            .map { ($0, Distance.meters(from: stationCoord, to: ($0.latitude, $0.longitude))) }
            .sorted { $0.1 < $1.1 }
        if let closest = candidates.first {
            let vehicleCoord = (lat: closest.0.latitude, lon: closest.0.longitude)
            let routeStations = MetraStationCatalog.stations(onRoute: route)
                .filter { $0.id != station.id }
                .map { ($0.name, $0.latitude, $0.longitude) }
            let intermediate = intermediateStops(
                vehicle: vehicleCoord,
                userStop: stationCoord,
                candidates: routeStations,
                limit: 4
            )
            MareyProgressStrip(
                distanceMeters: closest.1,
                scaleMeters: max(closest.1, 3_000),
                accent: pinnedMetraAccent,
                vehicleLabel: closest.0.destinationName.map { "→ \($0)" } ?? "Metra",
                stopLabel: station.name,
                intermediateStops: intermediate
            )
        }
    }

    private var pinnedMetraAccent: Color {
        pinnedMetraRoute
            .flatMap { MetraStationCatalog.route(id: $0)?.swiftUIColor }
            ?? ChicagoPalette.bahama
    }

    private func setPinnedMetra(_ route: String?) {
        pinnedMetraRoute = route
        pinnedMetraStationId = nil
        pinnedMetraDirectionId = nil
        pinnedMetraDestination = nil
        model.saveManualRoutePreferences {
            $0.pinnedMetraRoute = route
            $0.pinnedMetraStationId = nil
            $0.pinnedMetraDirectionId = nil
            $0.pinnedMetraDestination = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedMetraStation(_ station: MetraStation) {
        pinnedMetraStationId = station.id
        pinnedMetraDirectionId = nil
        pinnedMetraDestination = nil
        model.saveManualRoutePreferences {
            $0.pinnedMetraStationId = station.id
            $0.pinnedMetraDirectionId = nil
            $0.pinnedMetraDestination = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func togglePinnedMetraDirection(_ choice: MetraDirectionChoice) {
        let isSame = pinnedMetraDirectionId == choice.directionId
            && pinnedMetraDestination == choice.destinationName
        pinnedMetraDirectionId = isSame ? nil : choice.directionId
        pinnedMetraDestination = isSame ? nil : choice.destinationName
        model.saveManualRoutePreferences {
            $0.pinnedMetraDirectionId = isSame ? nil : choice.directionId
            $0.pinnedMetraDestination = isSame ? nil : choice.destinationName
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bikes

    private var bikeCard: some View {
        ChicagoCard(title: "Closest e-bikes",
                    eyebrow: "Divvy",
                    ornament: .icon(systemName: "bicycle")) {
            let options = model.snapshot.nearbyBikeOptions
            if options.isEmpty {
                Text("No e-bikes within walking distance")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: ChicagoSpacing.xs) {
                    ForEach(Array(options.prefix(3).enumerated()), id: \.element.id) { index, option in
                        BikeOptionRow(option: option)
                        if index < min(options.count, 3) - 1 {
                            Rectangle()
                                .fill(ChicagoPalette.cornflower.opacity(0.25))
                                .frame(height: ChicagoSpacing.Stroke.hairline)
                        }
                    }
                    let showsMapLink = options.count > 1 || options.contains {
                        if case .freeFloating = $0 { return true }
                        return false
                    }
                    if showsMapLink {
                        Button {
                            model.activeDetail = .bikeNearest
                        } label: {
                            HStack(spacing: ChicagoSpacing.xs) {
                                Text(options.count > 1 ? "See all on map" : "See on map")
                                Image(systemName: "chevron.right")
                            }
                            .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                            .foregroundStyle(ChicagoPalette.flagBlue)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, ChicagoSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Near You (deduped by line / by route) — small multiples

    private var nearYouSection: some View {
        ChicagoCard(title: "Near you",
                    eyebrow: "Discover",
                    ornament: .icon(systemName: "location.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                if model.location.lastKnown == nil {
                    Text("Waiting for a location fix…")
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                } else {
                    nearbyLLines
                    if !nearbyLines.isEmpty || !nearbyBusRoutes.isEmpty || !nearbyMetraRoutes.isEmpty {
                        Rectangle()
                            .fill(ChicagoPalette.cornflower.opacity(0.4))
                            .frame(height: ChicagoSpacing.Stroke.hairline)
                    }
                    nearbyBuses
                    nearbyMetra
                }
            }
        }
    }

    @ViewBuilder
    private var nearbyLLines: some View {
        if !nearbyLines.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Trains within walking distance")
                SmallMultiplesRow(nearbyLines) { entry in
                    let arrival = arrivals(forLine: entry.line, station: entry.station).first
                    let minutes = arrival.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
                    ArrivalTile(
                        badge: RouteBadge(line: entry.line, size: .md),
                        minutes: minutes,
                        subtitle: entry.station.name
                    )
                }
            }
        } else {
            Text("No L lines within 1.5 km")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    @ViewBuilder
    private var nearbyBuses: some View {
        if !nearbyBusRoutes.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                HStack {
                    sectionLabel("Buses nearby")
                    Spacer()
                    Text("Tap to pin")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.light)
                }
                SmallMultiplesRow(nearbyBusRoutes) { entry in
                    let pred = predictions(for: entry.stop).first
                    let minutes = pred.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
                    ArrivalTile(
                        badge: RouteBadge(bus: entry.stop.route, size: .md),
                        minutes: minutes,
                        subtitle: entry.stop.name
                    )
                    .onTapGesture { setPinnedBus(entry.stop.route) }
                }
            }
        } else {
            Text("No bus routes within 1.5 km")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    @ViewBuilder
    private var nearbyMetra: some View {
        if !nearbyMetraRoutes.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                HStack {
                    sectionLabel("Metra nearby")
                    Spacer()
                    Text("Tap to pin")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.light)
                }
                SmallMultiplesRow(nearbyMetraRoutes) { entry in
                    let pred = metraPredictions(for: entry).first
                    DepartureTimeTile(
                        badge: RouteBadge(metra: entry.routeId, size: .md),
                        departureAt: pred?.arrivalAt,
                        subtitle: entry.station.name,
                        isAlert: pred.map { $0.isDelayed || $0.isCanceled } ?? false
                    )
                    .onTapGesture { setPinnedMetra(entry.routeId) }
                }
            }
        } else {
            Text("No Metra lines within 3 km")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    // MARK: - Derived "nearby" lists

    private var origin: (lat: Double, lon: Double)? {
        guard let loc = model.location.lastKnown else { return nil }
        return (loc.latitude, loc.longitude)
    }

    private var closedStationIds: Set<Int> {
        ClosedStationsAnalyzer.closedStationIds(from: model.snapshot.activeAlerts)
    }

    private var nearbyLines: [LineEntry] {
        guard let origin else { return [] }
        let stations = NearestStationResolver(maxDistanceMeters: 2_000)
            .all(
                within: 2_000,
                of: origin,
                catalog: LStationCatalog.all,
                excludingStationIds: closedStationIds
            )

        // Opportunistic walking-aware re-ranking: if MapKit has already
        // resolved a walking distance for this (origin-bucket, station)
        // pair via the pinned-line card, use it. Otherwise keep the
        // resolver's Haversine order. No new MapKit requests are kicked
        // off here — the "Near you" view is glanceable and we don't want
        // to fan out per-line walking queries on every refresh.
        let walkingResolver = model.walkingResolver
        let reranked: [(station: LStation, haversine: Double, rankingMeters: Double)] = stations
            .map { entry in
                let walking = walkingResolver.cached(
                    origin: origin,
                    stationId: entry.station.id
                )
                return (entry.station, entry.distance, walking?.meters ?? entry.distance)
            }
            .sorted { $0.rankingMeters < $1.rankingMeters }

        var byLine: [LineColor: (station: LStation, distance: Double)] = [:]
        for entry in reranked {
            for line in entry.station.servedLines {
                if byLine[line] == nil {
                    byLine[line] = (entry.station, entry.haversine)
                }
            }
        }

        return byLine
            .filter { $0.key != pinnedLine }
            .map { LineEntry(line: $0.key, station: $0.value.station, distance: $0.value.distance) }
            .sorted { $0.distance < $1.distance }
    }

    private var nearbyBusRoutes: [BusEntry] {
        guard let origin else { return [] }
        let resolver = NearestBusStopResolver(maxDistanceMeters: 1_500)
        let stops = resolver.nearest(to: origin, limit: 8, catalog: BusStopCatalog.all)
        return stops
            .filter { $0.route != pinnedBusRoute }
            .prefix(5)
            .map { stop -> BusEntry in
                let d = Distance.meters(
                    from: origin,
                    to: (stop.latitude, stop.longitude)
                )
                return BusEntry(stop: stop, distance: d)
            }
    }

    private var nearbyMetraRoutes: [MetraEntry] {
        guard let origin else { return [] }
        return NearestMetraStationResolver(maxDistanceMeters: 3_000)
            .nearestPerRoute(
                to: origin,
                limit: 5,
                catalog: MetraStationCatalog.all
            )
            .filter { $0.routeId != pinnedMetraRoute }
            .map { MetraEntry(routeId: $0.routeId, station: $0.station, distance: $0.distance) }
    }

    private func arrivals(forLine line: LineColor, station: LStation) -> [Arrival] {
        model.snapshot.trainArrivals
            .filter { $0.line == line && $0.stationId == station.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(3)
            .map { $0 }
    }

    private func predictions(for stop: BusStop) -> [BusPrediction] {
        model.snapshot.busPredictions
            .filter { $0.stopId == stop.id && $0.route == stop.route }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(3)
            .map { $0 }
    }

    private func metraPredictions(for entry: MetraEntry) -> [MetraPrediction] {
        model.snapshot.metraPredictions
            .filter { $0.stationId == entry.station.id && $0.routeId == entry.routeId }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Alerts

    private var relevantAlerts: [ServiceAlert] {
        var lines: Set<LineColor> = []
        if let line = plannedTripPin?.train?.line { lines.insert(line) }
        if let line = pinnedLine { lines.insert(line) }

        var busRoutes: Set<String> = []
        if let route = plannedTripPin?.bus?.route { busRoutes.insert(route) }
        if let route = pinnedBusRoute { busRoutes.insert(route) }

        var metraRoutes: Set<String> = []
        if let route = plannedTripPin?.metra?.routeId { metraRoutes.insert(route) }
        if let route = pinnedMetraRoute { metraRoutes.insert(route) }

        return model.snapshot.activeAlerts.filtered(
            forLines: lines,
            busRoutes: busRoutes,
            metraRoutes: metraRoutes
        )
    }

    @ViewBuilder
    private var alertsCard: some View {
        let alerts = relevantAlerts
        if !alerts.isEmpty {
            let title = (pinnedLine != nil || pinnedBusRoute != nil || pinnedMetraRoute != nil)
                ? "Alerts on your pinned routes"
                : "Service alerts"
            ChicagoCard(title: title,
                        eyebrow: "Heads up",
                        ornament: .star) {
                VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                    ForEach(alerts.prefix(3), id: \.id) { alert in
                        AlertRow(alert: alert,
                                 pinnedLine: pinnedLine,
                                 pinnedBusRoute: pinnedBusRoute,
                                 pinnedMetraRoute: pinnedMetraRoute)
                    }
                    Link(destination: alerts.first?.detailURL ?? ServiceAlert.detailsURL) {
                        HStack(spacing: 2) {
                            Text(alerts.first?.detailURL == ServiceAlert.metraDetailsURL
                                 ? "Details on metra.com"
                                 : "Details from transit agencies")
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.bahama)
                    }
                    .accessibilityLabel("Open service alerts")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Tiny helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(ChicagoTypography.displaySM(relativeTo: .caption))
            .tracking(0.5)
            .foregroundStyle(ChicagoPalette.bahama)
    }
}

// MARK: - Manual home-address entry

private struct HomeAddressEntry: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)
    @State private var status: HomeLookupStatus = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("123 N Main St, Chicago", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .submitLabel(.search)
                        .onSubmit(lookup)
                    Button {
                        lookup()
                    } label: {
                        Label("Look up", systemImage: "magnifyingglass")
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)

                    Button {
                        useCurrentLocation()
                    } label: {
                        Label("Use current location", systemImage: "location.fill")
                    }
                } header: {
                    Text("Home")
                }

                statusSection

                if let coordinate {
                    Section("Preview") {
                        Map(position: $camera, interactionModes: [.pan, .zoom]) {
                            Marker("Home", coordinate: coordinate).tint(ChicagoPalette.starRed)
                        }
                        .frame(height: 220)
                    }
                }
            }
            .navigationTitle("Home address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(coordinate == nil)
                }
            }
            .onAppear {
                if let existing = model.preferences.loadCommuteAnchors().home {
                    let coord = CLLocationCoordinate2D(latitude: existing.latitude, longitude: existing.longitude)
                    coordinate = coord
                    camera = .camera(MapCamera(centerCoordinate: coord, distance: 1_500))
                }
            }
        }
    }

    private var isSearching: Bool {
        if case .searching = status { return true }
        return false
    }

    @ViewBuilder private var statusSection: some View {
        switch status {
        case .idle:
            EmptyView()
        case .searching:
            Section {
                HStack {
                    ProgressView()
                    Text("Looking up…").foregroundStyle(.secondary)
                }
            }
        case .found(let label):
            Section {
                Label(label, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .error(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func lookup() {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        status = .searching
        Task { @MainActor in
            let result = await HomeGeocodeService.lookup(query)
            switch result {
            case .success(let hit):
                coordinate = hit.coordinate
                camera = .camera(MapCamera(centerCoordinate: hit.coordinate, distance: 1_500))
                status = .found(hit.label.isEmpty ? "Found" : hit.label)
            case .failure(let message):
                status = .error(message)
            }
        }
    }

    private func useCurrentLocation() {
        Task { @MainActor in
            await model.location.refreshLocation()
            guard let last = model.location.lastKnown else {
                status = .error("Waiting for a location fix.")
                return
            }
            let coord = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            coordinate = coord
            camera = .camera(MapCamera(centerCoordinate: coord, distance: 1_500))
            status = .found("Current location")
        }
    }

    private func save() {
        guard let coordinate else { return }
        model.setHomeAnchor(latitude: coordinate.latitude, longitude: coordinate.longitude)
        dismiss()
    }
}

private enum HomeLookupStatus {
    case idle
    case searching
    case found(String)
    case error(String)
}

private struct HomeGeocodeHit: Sendable {
    let coordinate: CLLocationCoordinate2D
    let label: String
}

private enum HomeGeocodeOutcome: Sendable {
    case success(HomeGeocodeHit)
    case failure(String)
}

private enum HomeGeocodeService {
    static func lookup(_ query: String) async -> HomeGeocodeOutcome {
        await Task.detached { () -> HomeGeocodeOutcome in
            do {
                let placemarks = try await CLGeocoder().geocodeAddressString(query)
                guard let placemark = placemarks.first, let location = placemark.location else {
                    return .failure("No results.")
                }
                let label = [placemark.name, placemark.locality]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                return .success(HomeGeocodeHit(coordinate: location.coordinate, label: label))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}

// MARK: - Alert row

private struct AlertRow: View {
    let alert: ServiceAlert
    let pinnedLine: LineColor?
    let pinnedBusRoute: String?
    let pinnedMetraRoute: String?

    var body: some View {
        HStack(alignment: .top, spacing: ChicagoSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(severityColor)
                .accessibilityHidden(true)
            badge
            Text(alert.headline)
                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var severityColor: Color {
        switch alert.severity {
        case .high:   return ChicagoPalette.starRed
        case .medium: return ChicagoPalette.gold
        case .low:    return ChicagoPalette.bahama
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let line = pinnedLine, alert.impactedLineColors.contains(line) {
            RouteBadge(line: line, size: .sm)
        } else if let route = pinnedBusRoute, alert.impactedRoutes.contains(route) {
            RouteBadge(bus: route, size: .sm)
        } else if let route = pinnedMetraRoute, alert.impactedRoutes.contains(route) {
            RouteBadge(metra: route, size: .sm)
        } else if let line = alert.impactedLineColors.first {
            RouteBadge(line: line, size: .sm)
        } else if let route = alert.impactedRoutes.first,
                  MetraStationCatalog.route(id: route) != nil {
            RouteBadge(metra: route, size: .sm)
        } else if let route = alert.impactedRoutes.first {
            RouteBadge(bus: route, size: .sm)
        } else {
            EmptyView()
        }
    }

    private var accessibilitySummary: String {
        let lineLabel: String
        if let line = pinnedLine, alert.impactedLineColors.contains(line) {
            lineLabel = "\(line.displayName) line"
        } else if let route = pinnedBusRoute, alert.impactedRoutes.contains(route) {
            lineLabel = "Route \(route)"
        } else if let route = pinnedMetraRoute, alert.impactedRoutes.contains(route) {
            lineLabel = "Metra \(route)"
        } else if let line = alert.impactedLineColors.first {
            lineLabel = "\(line.displayName) line"
        } else if let route = alert.impactedRoutes.first,
                  MetraStationCatalog.route(id: route) != nil {
            lineLabel = "Metra \(route)"
        } else if let route = alert.impactedRoutes.first {
            lineLabel = "Route \(route)"
        } else {
            lineLabel = "Service"
        }
        return "\(lineLabel) alert: \(alert.headline)"
    }
}

// MARK: - Row entry types

private struct LineEntry: Identifiable {
    let line: LineColor
    let station: LStation
    let distance: Double
    var id: LineColor { line }
}

private struct BusEntry: Identifiable {
    let stop: BusStop
    let distance: Double
    var id: String { "\(stop.id)-\(stop.route)" }
}

private struct MetraEntry: Identifiable {
    let routeId: String
    let station: MetraStation
    let distance: Double
    var id: String { "\(routeId)-\(station.id)" }
}

private struct BusDirectionStopChoice: Identifiable {
    let directionLabel: String
    let stops: [BusStopChoice]

    var id: String { directionLabel }

    var displayLabel: String {
        if !directionLabel.isEmpty { return directionLabel }
        return stops.first?.stop.name ?? "Stops"
    }
}

private struct BusStopChoice: Identifiable {
    let stop: BusStop
    let distance: Double

    var id: Int { stop.id }
}

private struct MetraStationChoice: Identifiable {
    let station: MetraStation
    let distance: Double

    var id: String { station.id }
}

private struct HomeTripOption: Identifiable {
    let id = UUID()
    let title: String
    let transitSummary: String
    let expectedTravelTime: TimeInterval
    let totalDistanceMeters: Double
    let trainChoices: [HomeTripTrainChoice]
    let busChoices: [HomeTripBusChoice]
    let metraChoices: [HomeTripMetraChoice]
}

private struct HomeTripTrainChoice: Identifiable, Hashable {
    let line: LineColor
    let stationId: Int
    let stationName: String
    let distanceMeters: Double
    let legIndex: Int

    var id: String { "train-\(legIndex)-\(line.rawValue)-\(stationId)" }

    var displayLabel: String {
        "\(line.shortName) · \(stationName)"
    }
}

private struct HomeTripBusChoice: Identifiable, Hashable {
    let route: String
    let stopId: Int
    let stopName: String
    let directionLabel: String
    let distanceMeters: Double
    let legIndex: Int

    var id: String { "bus-\(legIndex)-\(route)-\(stopId)-\(directionLabel)" }

    var displayLabel: String {
        let direction = directionLabel.isEmpty ? "" : " \(directionLabel)"
        return "#\(route)\(direction) · \(stopName)"
    }
}

private struct HomeTripMetraChoice: Identifiable, Hashable {
    let routeId: String
    let stationId: String
    let stationName: String
    let directionId: Int?
    let destinationName: String?
    let distanceMeters: Double
    let legIndex: Int

    var id: String {
        "metra-\(legIndex)-\(routeId)-\(stationId)-\(directionId.map(String.init) ?? "any")"
    }

    var displayLabel: String {
        let route = MetraStationCatalog.route(id: routeId)?.shortName ?? routeId
        return "\(route) · \(stationName)"
    }
}

// MARK: - Chips

private struct DirectionChip: View {
    let label: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(ChicagoTypography.displaySM(relativeTo: .caption))
                .tracking(0.5)
                .foregroundStyle(isSelected ? .white : ChicagoPalette.Gray.darkest)
                .padding(.horizontal, ChicagoSpacing.md)
                .padding(.vertical, ChicagoSpacing.xs + 2)
                .background(
                    Capsule()
                        .fill(isSelected ? accent : ChicagoPalette.Surface.elevated)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? .clear : ChicagoPalette.cornflower.opacity(0.5),
                            lineWidth: ChicagoSpacing.Stroke.thin
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct LineChip: View {
    let line: LineColor
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(line: line, size: .sm)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(line.swiftUIColor)
                }
            }
            .padding(.horizontal, ChicagoSpacing.sm)
            .padding(.vertical, ChicagoSpacing.xs)
            .background(
                Capsule()
                    .fill(isPinned ? line.swiftUIColor.opacity(0.12) : ChicagoPalette.Surface.elevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isPinned ? line.swiftUIColor : ChicagoPalette.cornflower.opacity(0.5),
                        lineWidth: isPinned
                            ? ChicagoSpacing.Stroke.regular
                            : ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct StationChipStrip<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: ChicagoSpacing.xs) {
                content
            }
            .padding(.bottom, 1)
        }
    }
}

private struct StationChip: View {
    let station: LStation
    let travelTime: TimeInterval
    let isApproximateTravelTime: Bool
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? .white : ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text(secondaryLabel)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : ChicagoPalette.Gray.medium)
            }
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.vertical, ChicagoSpacing.sm)
            .frame(minWidth: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .fill(isSelected ? accent : ChicagoPalette.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .strokeBorder(
                        isSelected ? .clear : ChicagoPalette.cornflower.opacity(0.5),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.name), \(accessibilityTimeLabel)")
    }

    private var secondaryLabel: String {
        let minutes = max(1, Int((travelTime / 60).rounded()))
        return "\(isApproximateTravelTime ? "≈" : "")\(minutes) min walk"
    }

    private var accessibilityTimeLabel: String {
        let minutes = max(1, Int((travelTime / 60).rounded()))
        return "\(isApproximateTravelTime ? "about " : "")\(minutes) minute walk"
    }
}

private struct BusStopChip: View {
    let stop: BusStop
    let distance: Double
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? .white : ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text(WalkTimeFormatter.short(distanceMeters: distance))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : ChicagoPalette.Gray.medium)
            }
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.vertical, ChicagoSpacing.sm)
            .frame(minWidth: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .fill(isSelected ? accent : ChicagoPalette.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .strokeBorder(
                        isSelected ? .clear : ChicagoPalette.cornflower.opacity(0.5),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stop.name), \(WalkTimeFormatter.accessibility(distanceMeters: distance))")
    }
}

private struct MetraStationChip: View {
    let station: MetraStation
    let distance: Double
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? .white : ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text(WalkTimeFormatter.short(distanceMeters: distance))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : ChicagoPalette.Gray.medium)
            }
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.vertical, ChicagoSpacing.sm)
            .frame(minWidth: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .fill(isSelected ? accent : ChicagoPalette.Surface.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .strokeBorder(
                        isSelected ? .clear : ChicagoPalette.cornflower.opacity(0.5),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.name), \(WalkTimeFormatter.accessibility(distanceMeters: distance))")
    }
}

/// Shown for the first ~300ms a pinned-line card sits at a new origin
/// before MapKit walking distances land. Uses `.redacted(.placeholder)`
/// for the desaturated bar appearance and a gentle opacity pulse so it
/// reads as "loading," not as static greyed-out content. Same outer
/// dimensions as `StationChip` so the layout doesn't jump when real
/// chips replace it.
private struct StationChipPlaceholder: View {
    @State private var pulse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Station Name")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .lineLimit(1)
            Text("12 min walk")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .monospacedDigit()
        }
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.sm)
        .frame(minWidth: 132, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .fill(ChicagoPalette.Surface.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(
                    ChicagoPalette.cornflower.opacity(0.5),
                    lineWidth: ChicagoSpacing.Stroke.thin
                )
        )
        .redacted(reason: .placeholder)
        .opacity(pulse ? 0.5 : 0.9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Formatters

private enum DistanceFormatter {
    static func short(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters)) m"
        } else {
            return String(format: "%.1f km", meters / 1_000)
        }
    }
}

private enum WalkTimeFormatter {
    private static let walkingMetersPerMinute = 84.0

    static func short(distanceMeters: Double) -> String {
        let minutes = minutes(for: distanceMeters)
        return "≈\(minutes) min walk"
    }

    static func accessibility(distanceMeters: Double) -> String {
        let minutes = minutes(for: distanceMeters)
        return "about \(minutes) minute walk"
    }

    private static func minutes(for distanceMeters: Double) -> Int {
        max(1, Int((distanceMeters / walkingMetersPerMinute).rounded()))
    }
}

// MARK: - Bike rows

private struct BikeOptionRow: View {
    let option: NearbyBikeOption

    var body: some View {
        switch option {
        case .station(let pick):
            stationRow(pick)
        case .freeFloating(let pick):
            freeBikeRow(pick)
        }
    }

    private func stationRow(_ pick: NearestBikePick) -> some View {
        Button(action: { openStationInAppleMaps(pick) }) {
            bikeRowLayout(
                title: pick.station.name,
                subtitle: "\(pick.walkingMinutes) min walk",
                trailing: BikeInventorySummary(
                    dockedCount: pick.station.eBikesAvailable,
                    chargeSummary: pick.dockedChargeSummary,
                    scarce: pick.station.isScarce
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pick.station.name), \(pick.walkingMinutes) minute walk, \(pick.station.eBikesAvailable) docked e-bikes available")
        .accessibilityHint("Opens this station in Apple Maps")
    }

    private func freeBikeRow(_ pick: NearestFreeBikePick) -> some View {
        Button(action: { openFreeBikeInAppleMaps(pick) }) {
            bikeRowLayout(
                title: "Free e-bike",
                subtitle: "\(pick.walkingMinutes) min walk",
                trailing: VStack(alignment: .trailing, spacing: ChicagoSpacing.xs) {
                    Image(systemName: "bicycle")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ChicagoPalette.green)
                    Text("\(Int(pick.bestRangeMiles.rounded())) mi charge")
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Free e-bike, \(pick.walkingMinutes) minute walk, \(Int(pick.bestRangeMiles.rounded())) miles of range")
        .accessibilityHint("Opens this e-bike in Apple Maps")
    }

    private func bikeRowLayout<Trailing: View>(
        title: String,
        subtitle: String,
        trailing: Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: ChicagoSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ChicagoTypography.displaySM())
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            Spacer(minLength: ChicagoSpacing.sm)
            trailing
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .padding(.vertical, ChicagoSpacing.xs)
    }

    private func openStationInAppleMaps(_ pick: NearestBikePick) {
        let coord = CLLocationCoordinate2D(
            latitude: pick.station.latitude,
            longitude: pick.station.longitude
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = pick.station.name
        item.openInMaps()
    }

    private func openFreeBikeInAppleMaps(_ pick: NearestFreeBikePick) {
        let coord = CLLocationCoordinate2D(
            latitude: pick.bike.latitude,
            longitude: pick.bike.longitude
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = "Free e-bike"
        item.openInMaps()
    }
}
