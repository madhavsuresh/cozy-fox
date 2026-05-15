import ChicagoTheme
import CoreLocation
import MapKit
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI
import UIKit

struct DashboardScreen: View {
    @Environment(AppViewModel.self) private var model
    @State private var pinnedLine: LineColor?
    @State private var pinnedStationId: Int?
    @State private var pinnedTrainDestinations: [String]?
    @State private var pinnedBusRoute: String?
    @State private var pinnedBusDirection: String?
    @State private var pinnedBusStopId: Int?
    @State private var pinnedMetraRoute: String?
    @State private var pinnedMetraStationId: String?
    @State private var pinnedMetraDirectionId: Int?
    @State private var pinnedMetraDestination: String?
    @State private var includeIntercampus: Bool = false
    @State private var pinnedIntercampusDirection: IntercampusDirection?
    @State private var pinnedIntercampusStopId: String?
    @State private var pinSource: RoutePinSource = .manual
    @State private var autoPinnedDirection: CommuteDirection?
    @State private var plannedTripPin: PlannedTripPin?
    @State private var routePreferences: UserRoutePreferences = .empty
    @State private var commuteAnchors: CommuteAnchors = .empty
    @State private var selectedTripDestination: PlannedTripPin.Destination?
    @State private var destinationQuery: String = ""
    @State private var destinationSuggestions: [DestinationSuggestion] = []
    @State private var destinationDebounceTask: Task<Void, Never>?
    @State private var destinationResolveTask: Task<Void, Never>?
    @State private var anchorEntryKind: DestinationAnchorKind?
    @State private var destinationSearch = TripDestinationSearch(region: .chicagoLoop)
    @State private var isPinningHome: Bool = false
    @State private var homePinStatusText: String?
    @State private var homePinStatusIsError: Bool = false
    @State private var homeTripOptions: [HomeTripOption] = []
    @State private var selectedTrainChoiceIds: Set<String> = []
    @State private var selectedBusChoiceIds: Set<String> = []
    @State private var selectedMetraChoiceIds: Set<String> = []
    @State private var selectedIntercampusChoiceIds: Set<String> = []
    @State private var includeDivvyInfoForTripPin: Bool = true
    @FocusState private var isDestinationSearchFocused: Bool
    /// Flipped to `true` 300ms after the pinned-line card mounts (or
    /// re-mounts at a new origin/line) if MapKit hasn't produced any
    /// walking data yet. While false, the chip strip shows shimmer
    /// placeholders so the user doesn't see a stale Haversine ordering
    /// for a flicker before MapKit refines.
    @State private var allowHaversineFallback: Bool = false
    @State private var allowIntercampusHaversineFallback: Bool = false
    /// Memoized closed-station IDs derived from `model.snapshot.activeAlerts`.
    /// `ClosedStationsAnalyzer.closedStationIds` is O(alerts × stations × text
    /// search) and was being recomputed at every read site (currently 4 per
    /// body re-eval). Cache the result and refresh only when the alerts
    /// array changes — a body re-eval no longer triggers the scan.
    @State private var closedStationIdsCache: Set<Int> = []

    private let tripPlanner = TripPlanner()
    private let tripDivvyResolver = TripDivvyResolver(radiusMeters: 400)
    private let intercampusStopResolver = NearestIntercampusStopResolver(maxDistanceMeters: 2_000)
    private let corridorResolver = TransitCorridorResolver()

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    // `LazyVStack` so cards below the fold (typically Metra
                    // + Divvy + planned-trip when no pin is active) skip
                    // their body computation until the user scrolls them
                    // in — keeps the initial layout cheap on a dashboard
                    // with 10+ heavy cards.
                    LazyVStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                        if shouldShowAutopinBanner {
                            contextBanner
                        }
                        liveUpdatesBar
                        headHomeCard
                        pleasantSurpriseCard
                        portfolioSection
                        if shouldShowIntercampusSurface {
                            intercampusCard
                                .id(DashboardRailDestination.intercampus)
                        }
                        if shouldShowTrainSurfaces {
                            linePickerCard
                                .id(DashboardRailDestination.trainPicker)
                        }
                        if let line = pinnedLine {
                            pinnedLineCard(line: line)
                                .id(DashboardRailDestination.pinnedTrain)
                        }
                        if shouldShowBusSurfaces {
                            busRoutePickerCard
                                .id(DashboardRailDestination.busPicker)
                        }
                        if let route = pinnedBusRoute {
                            pinnedBusCard(route: route)
                                .id(DashboardRailDestination.pinnedBus)
                        }
                        if shouldShowMetraSurfaces {
                            metraRoutePickerCard
                                .id(DashboardRailDestination.metraPicker)
                        }
                        if let route = pinnedMetraRoute {
                            pinnedMetraCard(route: route)
                                .id(DashboardRailDestination.pinnedMetra)
                        }
                        if routePreferences.isModeVisible(.bikes) {
                            bikeCard
                        }
                        homePinControl
                        if let plannedTripPin {
                            activeHomeTripCard(plannedTripPin)
                                .id(DashboardRailDestination.plannedTrip)
                        } else if !homeTripOptions.isEmpty {
                            homeTripOptionsCard
                        }
                        if shouldShowDiscovery {
                            nearYouSection
                        } else if canOfferNearbyDiscovery {
                            showNearbyButton
                        }
                    }
                    .padding(ChicagoSpacing.md)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    topPinnedRoutesRail(scrollProxy: scrollProxy)
                }
                .background(ChicagoPalette.Surface.background)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: ChicagoSpacing.xs) {
                            ChicagoStar()
                                .fill(ChicagoPalette.starRed)
                                .frame(width: 14, height: 14)
                            Text("Cozy Fox")
                                .font(ChicagoTypography.body(.bold, relativeTo: .headline))
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
                .onAppear {
                    reloadPinnedFromPreferences()
                    recomputeClosedStationIdsIfNeeded()
                }
                .task { await observeDestinationSuggestions() }
                .onDisappear {
                    destinationDebounceTask?.cancel()
                    destinationResolveTask?.cancel()
                }
                .onChange(of: model.pinRevision) { _, _ in reloadPinnedFromPreferences() }
                .onChange(of: model.snapshot.activeAlerts) { _, _ in
                    recomputeClosedStationIdsIfNeeded()
                }
                .sheet(item: $anchorEntryKind, onDismiss: reloadPinnedFromPreferences) { kind in
                    AnchorAddressEntry(kind: kind)
                        .environment(model)
                }
            }
        }
        .dismissKeyboardOnTapAway()
    }

    private func reloadPinnedFromPreferences() {
        let prefs = model.preferences.loadRoutePreferences()
        routePreferences = prefs
        pinnedLine = prefs.pinnedLine
        pinnedStationId = prefs.pinnedStationId
        pinnedTrainDestinations = prefs.pinnedTrainDestinations
        pinnedBusRoute = prefs.pinnedBusRoute
        pinnedBusDirection = prefs.pinnedBusDirection
        pinnedBusStopId = prefs.pinnedBusStopId
        pinnedMetraRoute = prefs.pinnedMetraRoute
        pinnedMetraStationId = prefs.pinnedMetraStationId
        pinnedMetraDirectionId = prefs.pinnedMetraDirectionId
        pinnedMetraDestination = prefs.pinnedMetraDestination
        includeIntercampus = prefs.includeIntercampus
        pinnedIntercampusDirection = prefs.pinnedIntercampusDirection
        pinnedIntercampusStopId = prefs.pinnedIntercampusStopId
        pinSource = prefs.pinSource
        autoPinnedDirection = prefs.autoPinnedDirection
        plannedTripPin = prefs.plannedTripPin
        selectedTripDestination = selectedTripDestination ?? prefs.plannedTripPin?.destination
        commuteAnchors = model.preferences.loadCommuteAnchors()
    }

    private var shouldShowTrainSurfaces: Bool {
        routePreferences.isModeVisible(.trains)
    }

    private var shouldShowBusSurfaces: Bool {
        routePreferences.isModeVisible(.buses)
    }

    private var shouldShowMetraSurfaces: Bool {
        routePreferences.isModeVisible(.metra)
    }

    private var shouldShowIntercampusSurface: Bool {
        (includeIntercampus
            && (routePreferences.isModeVisible(.intercampus) || pinnedIntercampusStopId != nil)
        ) || plannedTripHasIntercampus
    }

    private var plannedTripHasIntercampus: Bool {
        plannedTripPin?.intercampusLegs.isEmpty == false
    }

    private var activeIntercampusRailDirection: IntercampusDirection? {
        pinnedIntercampusDirection ?? plannedTripPin?.intercampus?.direction
    }

    private var shouldShowDiscovery: Bool {
        guard routePreferences.nearbyDiscoveryEnabled else { return false }
        return routePreferences.isModeVisible(.trains)
            || routePreferences.isModeVisible(.buses)
            || routePreferences.isModeVisible(.metra)
    }

    /// `true` when at least one transit mode is visible — i.e. nearby
    /// discovery would have something to show if the user enabled it.
    /// Used to hide the inline "Show nearby" button entirely when all
    /// modes are off (no point offering it).
    private var canOfferNearbyDiscovery: Bool {
        routePreferences.isModeVisible(.trains)
            || routePreferences.isModeVisible(.buses)
            || routePreferences.isModeVisible(.metra)
    }

    private func isTrainLineDiscoverable(_ line: LineColor) -> Bool {
        routePreferences.isTrainLineVisible(line)
    }

    private func isBusRouteDiscoverable(_ route: String) -> Bool {
        routePreferences.isBusRouteVisible(route)
    }

    private func isMetraRouteDiscoverable(_ routeId: String) -> Bool {
        routePreferences.isMetraRouteVisible(routeId)
    }

    // MARK: - Head home tile

    /// Surfaces a quiet "head home?" suggestion when the user has been
    /// `.elsewhere` for a while and it's evening or their typical
    /// back-home window. Tapping "Plan trip" triggers the same flow
    /// as picking Home in the destination picker, so the existing
    /// trip-options UI takes it from there. Dismissable for the
    /// current session via "Not yet".
    @ViewBuilder
    private var headHomeCard: some View {
        let shouldShow = HomewardSuggester().shouldSurface(
            context: model.location.context,
            elsewhereSince: model.preferences.loadElsewhereSince(),
            anchors: commuteAnchors,
            profile: model.preferences.loadMobilityProfile(),
            now: Date(),
            suppressedUntil: model.homewardSuppressedUntil
        )
        if shouldShow {
            let lastWarning = lastTrainWarning()
            let copy: String = {
                if let lastWarning {
                    return "Last train in ~\(lastWarning.minutesUntilLast)m. Plan now?"
                }
                return "Plan a route from where you are."
            }()
            HStack(spacing: ChicagoSpacing.md) {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    Text("Head home?")
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    Text(copy)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(2)
                }
                Spacer()
                Button("Plan trip") {
                    planAnchoredTrip(.home)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(ChicagoPalette.flagBlue)
                Button {
                    model.suppressHomeward(for: 2 * 60 * 60)
                } label: {
                    Image(systemName: "xmark")
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Dismiss head-home suggestion")
            }
            .padding(ChicagoSpacing.md)
            .background(
                lastWarning != nil
                    ? AnyShapeStyle(ChicagoPalette.starRed.opacity(0.10))
                    : AnyShapeStyle(ChicagoPalette.Surface.elevated),
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
            )
        }
    }

    /// Real-time "last train looks soon" check. Fires when the user is
    /// `.elsewhere`, their habitual home-bound pattern is a train,
    /// and the current snapshot's arrivals for that (line, station)
    /// are sparse + winding down. Returns nil otherwise.
    private func lastTrainWarning() -> LastTrainSafety.Warning? {
        guard model.location.context == .elsewhere else { return nil }
        let profile = model.preferences.loadMobilityProfile()
        guard let homePattern = profile.summary.patterns(direction: .toHome)
            .sorted(by: { $0.totalCount > $1.totalCount })
            .first,
            homePattern.mode == .train,
            let line = LineColor(rawValue: homePattern.routeId),
            let stationIdString = homePattern.topStationId,
            let stationId = Int(stationIdString)
        else { return nil }

        let relevantArrivals = model.snapshot.trainArrivals
            .filter { $0.line == line && $0.stationId == stationId }
        return LastTrainSafety().warning(forArrivals: relevantArrivals)
    }

    // MARK: - Pleasant-surprise tile

    /// Compute a pleasant-surprise suggestion for the current
    /// commute moment: when context is `.atHome` or `.atWork` and the
    /// user has a top route + the opposite anchor set. Returns nil
    /// otherwise. Result is recomputed each render — pure function of
    /// observable state, fast (catalog scans are linear in stations/
    /// routes, both bounded under 150).
    private func pleasantSurpriseSuggestion() -> PleasantSurpriseSuggester.Suggestion? {
        let anchors = commuteAnchors
        let context = model.location.context
        let origin: (lat: Double, lon: Double)?
        let destination: (lat: Double, lon: Double)?
        let currentDirection: CommuteDirection
        switch context {
        case .atHome:
            origin = anchors.home.map { (lat: $0.latitude, lon: $0.longitude) }
            destination = anchors.work.map { (lat: $0.latitude, lon: $0.longitude) }
            currentDirection = .toWork
        case .atWork:
            origin = anchors.work.map { (lat: $0.latitude, lon: $0.longitude) }
            destination = anchors.home.map { (lat: $0.latitude, lon: $0.longitude) }
            currentDirection = .toHome
        case .elsewhere, .unknown:
            return nil
        }
        guard let origin, let destination else { return nil }

        let profile = model.preferences.loadMobilityProfile()
        guard let usualPattern = profile.summary.patterns(direction: currentDirection)
            .sorted(by: { $0.totalCount > $1.totalCount })
            .first
        else { return nil }

        let enumerator = AlternativeRouteEnumerator()
        guard let enumeration = enumerator.enumerate(
            origin: origin,
            destination: destination,
            usualPattern: usualPattern
        ) else { return nil }

        let geographyIndex = OffCommuteGeographyIndex.build(
            from: profile.routeObservations,
            currentCommute: currentDirection
        )

        let suggester = PleasantSurpriseSuggester()
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        return suggester.suggest(
            currentContext: context,
            profile: profile,
            alternatives: enumeration.alternatives,
            usualTripSeconds: enumeration.usualTripSeconds,
            isSuppressed: { key in model.suggestionSuppression.isSuppressed(key) },
            recentObservationCutoff: cutoff,
            delightScore: { alt in
                let waypoints = enumerator.waypoints(
                    mode: alt.mode,
                    routeId: alt.routeId,
                    origin: origin,
                    destination: destination
                )
                return geographyIndex.delightScore(forPolyline: waypoints)
            }
        )
    }

    @ViewBuilder
    private var pleasantSurpriseCard: some View {
        if let suggestion = pleasantSurpriseSuggestion() {
            HStack(spacing: ChicagoSpacing.md) {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    Text("Try something different today?")
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    Text(suggestion.prose)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(2)
                    if suggestion.delight > 0.25 {
                        Text("Passes places you've been.")
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.light)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("Try it") {
                    pinPleasantSurprise(suggestion)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(ChicagoPalette.flagBlue)
                Button {
                    model.suggestionSuppression.suppress(
                        suggestion.routeKey,
                        for: 7 * 86_400
                    )
                } label: {
                    Image(systemName: "xmark")
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Dismiss this suggestion for a week")
            }
            .padding(ChicagoSpacing.md)
            .background(
                ChicagoPalette.Surface.elevated,
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
            )
        }
    }

    /// User accepted the pleasant-surprise — pin the alternative as
    /// the current route preference. The dashboard's pinned card will
    /// re-render to reflect the new choice. Also suppresses the same
    /// suggestion for a week so we don't keep suggesting what they
    /// already took.
    private func pinPleasantSurprise(_ suggestion: PleasantSurpriseSuggester.Suggestion) {
        model.suggestionSuppression.suppress(suggestion.routeKey, for: 7 * 86_400)
        model.saveManualRoutePreferences { prefs in
            switch suggestion.mode {
            case .train:
                if let line = LineColor(rawValue: suggestion.routeId) {
                    prefs.pinnedLine = line
                    prefs.pinnedStationId = nil
                    prefs.pinnedTrainDestinations = nil
                }
            case .bus:
                prefs.pinnedBusRoute = suggestion.routeId
                prefs.pinnedBusDirection = nil
                prefs.pinnedBusStopId = nil
            case .metra:
                break
            }
        }
    }

    // MARK: - Destination pin

    private var homePinControl: some View {
        ChicagoCard(title: "Destination",
                    eyebrow: "Trip pin",
                    ornament: .icon(systemName: "location.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                HStack(spacing: ChicagoSpacing.sm) {
                    destinationAnchorButton(.home)
                    destinationAnchorButton(.work)
                }

                HStack(spacing: ChicagoSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                    TextField("Type a destination", text: $destinationQuery)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.go)
                        .focused($isDestinationSearchFocused)
                        .onSubmit { planTypedDestination() }
                        .onChange(of: destinationQuery) { _, newValue in
                            scheduleDestinationSearch(newValue)
                        }
                    if !destinationQuery.isEmpty {
                        Button {
                            destinationQuery = ""
                            destinationSuggestions = []
                            destinationSearch.setQuery("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ChicagoPalette.Gray.medium)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear destination")
                    }
                }
                .padding(.horizontal, ChicagoSpacing.sm)
                .padding(.vertical, ChicagoSpacing.xs)
                .background(ChicagoPalette.Surface.elevated,
                            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm))

                if !destinationSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        ForEach(destinationSuggestions.prefix(5)) { suggestion in
                            Button {
                                pickDestinationSuggestion(suggestion)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title)
                                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                                        .lineLimit(1)
                                    if !suggestion.subtitle.isEmpty {
                                        Text(suggestion.subtitle)
                                            .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                                            .foregroundStyle(ChicagoPalette.Gray.medium)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
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
                } else if model.location.lastKnown == nil {
                    destinationInlinePrompt("Waiting for your current location.")
                } else if commuteAnchors.home == nil {
                    destinationAnchorPrompt(.home)
                } else if commuteAnchors.work == nil {
                    destinationAnchorPrompt(.work)
                }
            }
        }
    }

    private func destinationAnchorButton(_ kind: DestinationAnchorKind) -> some View {
        let hasAnchor = kind.anchor(in: commuteAnchors) != nil
        return Button {
            planAnchoredTrip(kind)
        } label: {
            Label(hasAnchor ? kind.title : "Set \(kind.title.lowercased())", systemImage: kind.systemImage)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(kind.tint)
        .disabled(isPinningHome)
    }

    private func destinationAnchorPrompt(_ kind: DestinationAnchorKind) -> some View {
        HStack(spacing: ChicagoSpacing.sm) {
            destinationInlinePrompt("\(kind.title) is not set.")
            Spacer(minLength: ChicagoSpacing.sm)
            Button {
                anchorEntryKind = kind
            } label: {
                Label("Set \(kind.title.lowercased())", systemImage: "mappin.and.ellipse")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(kind.tint)
        }
    }

    private func destinationInlinePrompt(_ text: String) -> some View {
        Text(text)
            .font(ChicagoTypography.body(.regular, relativeTo: .caption))
            .foregroundStyle(ChicagoPalette.Gray.medium)
    }

    private func planAnchoredTrip(_ kind: DestinationAnchorKind) {
        isDestinationSearchFocused = false
        homePinStatusText = nil
        homePinStatusIsError = false
        guard let anchor = kind.anchor(in: commuteAnchors) else {
            anchorEntryKind = kind
            return
        }

        destinationQuery = kind.title
        destinationSuggestions = []
        planTrip(to: PlannedTripPin.Destination(
            kind: kind.destinationKind,
            title: kind.title,
            subtitle: anchor.label,
            latitude: anchor.latitude,
            longitude: anchor.longitude
        ))
    }

    @MainActor
    private func observeDestinationSuggestions() async {
        for await suggestions in destinationSearch.updates {
            destinationSuggestions = Array(suggestions.prefix(6))
        }
    }

    private func scheduleDestinationSearch(_ query: String) {
        destinationDebounceTask?.cancel()
        destinationDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            destinationSearch.setQuery(query)
        }
    }

    private func pickDestinationSuggestion(_ suggestion: DestinationSuggestion) {
        isDestinationSearchFocused = false
        destinationResolveTask?.cancel()
        isPinningHome = true
        homePinStatusText = nil
        homePinStatusIsError = false
        destinationResolveTask = Task { @MainActor in
            do {
                let resolved = try await destinationSearch.resolve(suggestion)
                guard !Task.isCancelled else { return }
                planResolvedDestination(resolved)
            } catch {
                homePinStatusText = error.localizedDescription
                homePinStatusIsError = true
                isPinningHome = false
            }
        }
    }

    private func planTypedDestination() {
        let query = destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isDestinationSearchFocused = false
        destinationResolveTask?.cancel()
        isPinningHome = true
        homePinStatusText = nil
        homePinStatusIsError = false
        destinationResolveTask = Task { @MainActor in
            do {
                let resolved = try await destinationSearch.resolve(query: query)
                guard !Task.isCancelled else { return }
                planResolvedDestination(resolved)
            } catch {
                homePinStatusText = error.localizedDescription
                homePinStatusIsError = true
                isPinningHome = false
            }
        }
    }

    private func planResolvedDestination(_ resolved: ResolvedDestination) {
        isDestinationSearchFocused = false
        destinationQuery = resolved.title
        destinationSuggestions = []
        planTrip(to: PlannedTripPin.Destination(
            kind: .custom,
            title: resolved.title,
            subtitle: resolved.subtitle.isEmpty ? nil : resolved.subtitle,
            latitude: resolved.coordinate.latitude,
            longitude: resolved.coordinate.longitude
        ))
    }

    private func planTrip(to destinationInfo: PlannedTripPin.Destination) {
        guard let current = model.location.lastKnown else {
            homePinStatusText = "Waiting for your current location."
            homePinStatusIsError = true
            return
        }
        guard let latitude = destinationInfo.latitude, let longitude = destinationInfo.longitude else {
            homePinStatusText = "Pick a destination from search."
            homePinStatusIsError = true
            return
        }

        selectedTripDestination = destinationInfo
        if plannedTripPin != nil {
            plannedTripPin = nil
            model.clearPlannedTripPin()
        }
        isPinningHome = true
        homeTripOptions = []
        selectedTrainChoiceIds = []
        selectedBusChoiceIds = []
        selectedMetraChoiceIds = []
        selectedIntercampusChoiceIds = []
        includeDivvyInfoForTripPin = true

        let origin = PlannerCoordinate(latitude: current.latitude, longitude: current.longitude)
        let destination = PlannerCoordinate(latitude: latitude, longitude: longitude)
        let profile = model.preferences.loadMobilityProfile()

        Task { @MainActor in
            do {
                let plans = try await tripPlanner.plan(
                    from: origin,
                    to: destination,
                    profile: profile
                )
                guard !Task.isCancelled else { return }
                let options = buildHomeTripOptions(
                    from: plans,
                    origin: origin,
                    destination: destination
                )
                homeTripOptions = options
                seedSelectedHomeTripChoices(from: options)
                ensureHomeTripAccessRoutes(
                    options,
                    origin: (lat: origin.latitude, lon: origin.longitude)
                )
                homePinStatusText = options.isEmpty
                    ? "No pin-ready transit legs found for \(destinationInfo.title)."
                    : "Choose the route pieces to pin."
                homePinStatusIsError = options.isEmpty
                isPinningHome = false
            } catch {
                homePinStatusText = error.localizedDescription
                homePinStatusIsError = true
                isPinningHome = false
            }
        }
    }

    private var homeTripOptionsCard: some View {
        ChicagoCard(title: "Trip to \(selectedTripDestination?.title ?? "destination")",
                    eyebrow: "Choose pin",
                    ornament: .icon(systemName: "point.topleft.down.curvedto.point.bottomright.up")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                homeTripPinControls

                Toggle(isOn: $includeDivvyInfoForTripPin) {
                    Label("Include Divvy", systemImage: "bicycle")
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                }
                .tint(ChicagoPalette.Mode.divvy)

                if includeDivvyInfoForTripPin {
                    tripDivvyContextRow(destination: selectedTripDestination)
                }

                Button {
                    pinSelectedHomeTrip()
                } label: {
                    Label("Pin selected pieces", systemImage: "pin.fill")
                        .font(ChicagoTypography.body(.medium, relativeTo: .callout))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ChicagoPalette.flagBlue)
                .disabled(!hasSelectedHomeTripPinPiece)
            }
        }
    }

    @ViewBuilder
    private var homeTripPinControls: some View {
        let trainLines = homeTripTrainLines(in: homeTripOptions)
        let busRoutes = homeTripBusRoutes(in: homeTripOptions)
        let metraRoutes = homeTripMetraRoutes(in: homeTripOptions)
        let intercampusChoices = homeTripIntercampusChoices(in: homeTripOptions)
        let selectedTrainLines = Set(selectedTrainChoices().map(\.line))
        let selectedBusRoutes = Set(selectedBusChoices().map(\.route))
        let selectedMetraRoutes = Set(selectedMetraChoices().map(\.routeId))

        VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
            if !trainLines.isEmpty {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    sectionLabel("Train")
                    StationChipStrip {
                        ForEach(trainLines, id: \.self) { line in
                            DirectionChip(
                                label: line.displayName,
                                isSelected: selectedTrainLines.contains(line),
                                accent: line.swiftUIColor,
                                action: { toggleSelectedTrainLine(line) }
                            )
                        }
                    }
                }

                ForEach(trainLines.filter { selectedTrainLines.contains($0) }, id: \.self) { selectedLine in
                    let stationChoices = homeTripTrainChoices(in: homeTripOptions)
                        .filter { $0.line == selectedLine }
                    if !stationChoices.isEmpty {
                        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                            sectionLabel("\(selectedLine.displayName) station")
                            StationChipStrip {
                                ForEach(stationChoices) { choice in
                                    DirectionChip(
                                        label: trainStationPinLabel(choice),
                                        isSelected: selectedTrainChoiceIds.contains(choice.id),
                                        accent: selectedLine.swiftUIColor,
                                        action: { toggleSelectedTrainChoice(choice) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if !busRoutes.isEmpty {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    sectionLabel("Bus")
                    StationChipStrip {
                        ForEach(busRoutes, id: \.self) { route in
                            DirectionChip(
                                label: "#\(route)",
                                isSelected: selectedBusRoutes.contains(route),
                                accent: ChicagoPalette.Mode.bus,
                                action: { toggleSelectedBusRoute(route) }
                            )
                        }
                    }
                }

                ForEach(busRoutes.filter { selectedBusRoutes.contains($0) }, id: \.self) { selectedRoute in
                    let stopChoices = homeTripBusChoices(in: homeTripOptions)
                        .filter { $0.route == selectedRoute }
                    if !stopChoices.isEmpty {
                        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                            sectionLabel("Route \(selectedRoute) stop")
                            StationChipStrip {
                                ForEach(stopChoices) { choice in
                                    DirectionChip(
                                        label: busStopPinLabel(choice),
                                        isSelected: selectedBusChoiceIds.contains(choice.id),
                                        accent: ChicagoPalette.Mode.bus,
                                        action: { toggleSelectedBusChoice(choice) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if !metraRoutes.isEmpty {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    sectionLabel("Metra")
                    StationChipStrip {
                        ForEach(metraRoutes, id: \.self) { routeId in
                            DirectionChip(
                                label: MetraStationCatalog.route(id: routeId)?.shortName ?? routeId,
                                isSelected: selectedMetraRoutes.contains(routeId),
                                accent: MetraStationCatalog.route(id: routeId)?.swiftUIColor ?? ChicagoPalette.bahama,
                                action: { toggleSelectedMetraRoute(routeId) }
                            )
                        }
                    }
                }

                ForEach(metraRoutes.filter { selectedMetraRoutes.contains($0) }, id: \.self) { selectedRoute in
                    let stationChoices = homeTripMetraChoices(in: homeTripOptions)
                        .filter { $0.routeId == selectedRoute }
                    if !stationChoices.isEmpty {
                        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                            sectionLabel("\(MetraStationCatalog.route(id: selectedRoute)?.shortName ?? selectedRoute) station")
                            StationChipStrip {
                                ForEach(stationChoices) { choice in
                                    DirectionChip(
                                        label: metraStationPinLabel(choice),
                                        isSelected: selectedMetraChoiceIds.contains(choice.id),
                                        accent: MetraStationCatalog.route(id: selectedRoute)?.swiftUIColor ?? ChicagoPalette.bahama,
                                        action: { toggleSelectedMetraChoice(choice) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if !intercampusChoices.isEmpty {
                VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                    sectionLabel("Intercampus")
                    StationChipStrip {
                        ForEach(intercampusChoices) { choice in
                            DirectionChip(
                                label: intercampusPinLabel(choice),
                                isSelected: selectedIntercampusChoiceIds.contains(choice.id),
                                accent: ChicagoPalette.Mode.intercampus,
                                action: { toggleSelectedIntercampusChoice(choice) }
                            )
                        }
                    }
                }
            }
        }
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
                        plannedTripPin = nil
                        selectedTripDestination = nil
                        model.clearPlannedTripPin()
                    } label: {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Toggle(isOn: Binding(
                    get: { plannedTripPin?.includeDivvyInfo ?? pin.includeDivvyInfo },
                    set: { setPlannedTripDivvyInfo($0, for: pin) }
                )) {
                    Label("Include Divvy", systemImage: "bicycle")
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                }
                .tint(ChicagoPalette.Mode.divvy)

                if plannedTripPin?.includeDivvyInfo ?? pin.includeDivvyInfo {
                    tripDivvyContextRow(destination: pin.destination)
                }

                ForEach(pin.trainLegs, id: \.self) { train in
                    tripTrainRow(train)
                }
                ForEach(pin.busLegs, id: \.self) { bus in
                    tripBusRow(bus)
                }
                ForEach(pin.metraLegs, id: \.self) { metra in
                    tripMetraRow(metra)
                }
                ForEach(pin.intercampusLegs, id: \.self) { intercampus in
                    tripIntercampusRow(intercampus)
                }
            }
        }
    }

    private func setPlannedTripDivvyInfo(_ includeDivvyInfo: Bool, for pin: PlannedTripPin) {
        let updated = (plannedTripPin ?? pin).withIncludeDivvyInfo(includeDivvyInfo)
        plannedTripPin = updated
        model.updatePlannedTripPin(updated)
    }

    private func tripDivvyContextRow(destination: PlannedTripPin.Destination?) -> some View {
        TripDivvyContextRow(
            originStations: tripDivvyOriginStationPicks(),
            freeFloatingBikeCount: tripDivvyFreeFloatingBikeCount(),
            destinationDockStations: tripDivvyDestinationDockPicks(destination)
        )
    }

    private func tripDivvyOriginStationPicks() -> [TripDivvyStationPick] {
        guard let origin = model.location.lastKnown else { return [] }
        return tripDivvyResolver.originStations(
            near: (origin.latitude, origin.longitude),
            stations: model.bikeInventory.stations,
            limit: 2
        )
    }

    private func tripDivvyDestinationDockPicks(
        _ destination: PlannedTripPin.Destination?
    ) -> [TripDivvyStationPick] {
        guard let latitude = destination?.latitude,
              let longitude = destination?.longitude
        else { return [] }

        return tripDivvyResolver.destinationDockStations(
            near: (latitude, longitude),
            stations: model.bikeInventory.stations,
            limit: 2
        )
    }

    private func tripDivvyFreeFloatingBikeCount() -> Int? {
        guard routePreferences.includeFreeFloatingBikes,
              let origin = model.location.lastKnown
        else { return nil }
        return tripDivvyResolver.freeFloatingEBikeCount(
            near: (origin.latitude, origin.longitude),
            eBikes: model.bikeInventory.eBikes,
            includeFreeFloating: true
        )
    }

    private func tripTrainRow(_ train: PlannedTripPin.TrainLeg) -> some View {
        let alerts = alerts(forLine: train.line)
        let arrivals = model.snapshot.trainArrivals
            .filter { $0.line == train.line }
            .filter { train.stationId == nil || $0.stationId == train.stationId }
            .filter { train.destinationName == nil || $0.destinationName == train.destinationName }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = arrivals.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        let assessments = ghostAssessments(for: arrivals)
        let firstAssessment = first.flatMap { assessments[$0.id] }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(line: train.line, size: .sm)
                Text(train.stationName)
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                Spacer()
            }
            if !alerts.isEmpty {
                pinAlertInlineSummary(alerts)
            }
            if let minutes, let first {
                let isGhostLikely = firstAssessment?.isGhostLikely == true
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed || isGhostLikely ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next \(train.line.displayName) train"
                    )
                    Text("→ \(first.destinationName)")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                if let badge = GhostTrainBadge(firstAssessment) {
                    badge
                }
                let tripTrainUrgencies = train.stationId.map {
                    departureUrgencies(forStationId: $0, arrivals: arrivals.prefix(8))
                } ?? []
                HeadwayDotStrip(arrivals: arrivals.prefix(8).map(\.arrivalAt),
                                accent: train.line.swiftUIColor,
                                complications: ghostComplications(
                                    for: arrivals.prefix(8),
                                    assessments: assessments
                                ),
                                urgencies: tripTrainUrgencies)
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
        let alerts = alerts(forBusRoute: bus.route)
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
            if !alerts.isEmpty {
                pinAlertInlineSummary(alerts)
            }
            if let minutes, let first {
                let biasCorrection = headlineBiasCorrection(for: predictions)
                let bunching = bunchingHint(for: predictions)
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
                if let biasCorrection {
                    Text(biasCorrection.displayText)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .accessibilityLabel(biasCorrection.accessibilityLabel)
                }
                if let bunching {
                    Text("+ another in \(bunching.minutes)m")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .accessibilityLabel("Another Route \(bus.route) bus in \(bunching.minutes) minutes")
                }
                let tripBusUrgencies = bus.stopId.map {
                    departureUrgencies(forBusStopId: $0, predictions: predictions.prefix(8))
                } ?? []
                HeadwayDotStrip(arrivals: predictions.prefix(8).map(\.arrivalAt),
                                accent: ChicagoPalette.Mode.bus,
                                urgencies: tripBusUrgencies)
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
        let alerts = alerts(forMetraRoute: metra.routeId)
        let predictions = model.snapshot.metraPredictions
            .filter { $0.routeId == metra.routeId }
            .filter { metra.stationId == nil || $0.stationId == metra.stationId }
            .filter { metra.directionId == nil || $0.directionId == metra.directionId }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let group = MetraDepartureGrouper.groups(from: predictions, limitPerGroup: 3).first
        let accent = MetraStationCatalog.route(id: metra.routeId)?.swiftUIColor ?? ChicagoPalette.bahama
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                RouteBadge(metra: metra.routeId, size: .sm)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metra.stationName)
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    if let group {
                        Text(group.title)
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                    }
                }
                Spacer()
            }
            if !alerts.isEmpty {
                pinAlertInlineSummary(alerts)
            }
            if let group {
                VStack(alignment: .leading, spacing: 2) {
                    MetraDepartureListView(
                        predictions: group.departures,
                        maxCount: 3,
                        density: .regular,
                        accessibilityPrefix: "Metra \(group.title.lowercased()) departures"
                    )
                }
                let tripMetraUrgencies = metra.stationId.map {
                    departureUrgencies(forMetraStationId: $0, predictions: group.departures.prefix(8))
                } ?? []
                HeadwayDotStrip(arrivals: group.departures.prefix(8).map(\.arrivalAt),
                                accent: accent,
                                urgencies: tripMetraUrgencies)
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

    private func tripIntercampusRow(_ intercampus: PlannedTripPin.IntercampusLeg) -> some View {
        let arrivals = model.snapshot.intercampusArrivals
            .filter { $0.direction == intercampus.direction && $0.stopId == intercampus.stopId }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = arrivals.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                IntercampusRailBadge(direction: intercampus.direction)
                VStack(alignment: .leading, spacing: 1) {
                    Text(intercampus.stopName)
                        .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                    Text(intercampus.direction.label)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
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
                        accessibilityLabel: "\(minutes) minutes to next Intercampus shuttle, \(first.timeSource.label.lowercased())"
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: ChicagoSpacing.xs) {
                            Text("→ \(first.destinationName)")
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                                .foregroundStyle(ChicagoPalette.Gray.medium)
                                .lineLimit(1)
                            intercampusTimeSourceBadge(first.timeSource)
                        }
                        if let vehicleLabel = first.vehicleLabel, !vehicleLabel.isEmpty {
                            Text("Bus \(vehicleLabel)")
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.Gray.light)
                                .lineLimit(1)
                        }
                    }
                }
                HeadwayDotStrip(
                    arrivals: arrivals.prefix(8).map(\.arrivalAt),
                    accent: ChicagoPalette.Mode.intercampus
                )
            } else {
                Text(model.isRefreshing ? "Fetching Intercampus arrivals…" : "No upcoming Intercampus arrivals returned yet.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var hasSelectedHomeTripPinPiece: Bool {
        !selectedTrainChoices().isEmpty
            || !selectedBusChoices().isEmpty
            || !selectedMetraChoices().isEmpty
            || !selectedIntercampusChoices().isEmpty
    }

    private func seedSelectedHomeTripChoices(from options: [HomeTripOption]) {
        guard let option = options.first else {
            selectedTrainChoiceIds = []
            selectedBusChoiceIds = []
            selectedMetraChoiceIds = []
            selectedIntercampusChoiceIds = []
            return
        }

        let trainChoices = homeTripTrainChoices(in: options)
        let busChoices = homeTripBusChoices(in: options)
        let metraChoices = homeTripMetraChoices(in: options)
        let intercampusChoices = homeTripIntercampusChoices(in: options)
        selectedTrainChoiceIds = Set(option.trainChoices.prefix(1).compactMap { selected in
            trainChoices.first { trainPinKey($0) == trainPinKey(selected) }?.id
        })
        selectedBusChoiceIds = Set(option.busChoices.prefix(1).compactMap { selected in
            busChoices.first { busPinKey($0) == busPinKey(selected) }?.id
        })
        selectedMetraChoiceIds = Set(option.metraChoices.compactMap { selected in
            metraChoices.first { metraPinKey($0) == metraPinKey(selected) }?.id
        })
        selectedIntercampusChoiceIds = Set(option.intercampusChoices.prefix(1).compactMap { selected in
            intercampusChoices.first { intercampusPinKey($0) == intercampusPinKey(selected) }?.id
        })
    }

    private func toggleSelectedTrainLine(_ line: LineColor) {
        let choices = homeTripTrainChoices(in: homeTripOptions)
        if selectedTrainChoices().contains(where: { $0.line == line }) {
            selectedTrainChoiceIds.subtract(choices.filter { $0.line == line }.map(\.id))
        } else {
            if let choice = choices.first(where: { $0.line == line }) {
                selectedTrainChoiceIds.insert(choice.id)
            }
        }
    }

    private func toggleSelectedBusRoute(_ route: String) {
        let choices = homeTripBusChoices(in: homeTripOptions)
        if selectedBusChoices().contains(where: { $0.route == route }) {
            selectedBusChoiceIds.subtract(choices.filter { $0.route == route }.map(\.id))
        } else {
            if let choice = choices.first(where: { $0.route == route }) {
                selectedBusChoiceIds.insert(choice.id)
            }
        }
    }

    private func toggleSelectedMetraRoute(_ routeId: String) {
        let choices = homeTripMetraChoices(in: homeTripOptions)
        if selectedMetraChoices().contains(where: { $0.routeId == routeId }) {
            selectedMetraChoiceIds.subtract(choices.filter { $0.routeId == routeId }.map(\.id))
        } else {
            if let choice = choices.first(where: { $0.routeId == routeId }) {
                selectedMetraChoiceIds.insert(choice.id)
            }
        }
    }

    private func toggleSelectedTrainChoice(_ choice: HomeTripTrainChoice) {
        if selectedTrainChoiceIds.contains(choice.id) {
            selectedTrainChoiceIds.remove(choice.id)
        } else {
            let sameLineIds = homeTripTrainChoices(in: homeTripOptions)
                .filter { $0.line == choice.line }
                .map(\.id)
            selectedTrainChoiceIds.subtract(sameLineIds)
            selectedTrainChoiceIds.insert(choice.id)
        }
    }

    private func toggleSelectedBusChoice(_ choice: HomeTripBusChoice) {
        if selectedBusChoiceIds.contains(choice.id) {
            selectedBusChoiceIds.remove(choice.id)
        } else {
            let sameRouteIds = homeTripBusChoices(in: homeTripOptions)
                .filter { $0.route == choice.route }
                .map(\.id)
            selectedBusChoiceIds.subtract(sameRouteIds)
            selectedBusChoiceIds.insert(choice.id)
        }
    }

    private func toggleSelectedMetraChoice(_ choice: HomeTripMetraChoice) {
        if selectedMetraChoiceIds.contains(choice.id) {
            selectedMetraChoiceIds.remove(choice.id)
        } else {
            let sameRouteIds = homeTripMetraChoices(in: homeTripOptions)
                .filter { $0.routeId == choice.routeId }
                .map(\.id)
            selectedMetraChoiceIds.subtract(sameRouteIds)
            selectedMetraChoiceIds.insert(choice.id)
        }
    }

    private func toggleSelectedIntercampusChoice(_ choice: HomeTripIntercampusChoice) {
        if selectedIntercampusChoiceIds.contains(choice.id) {
            selectedIntercampusChoiceIds.remove(choice.id)
        } else {
            let sameDirectionIds = homeTripIntercampusChoices(in: homeTripOptions)
                .filter { $0.direction == choice.direction }
                .map(\.id)
            selectedIntercampusChoiceIds.subtract(sameDirectionIds)
            selectedIntercampusChoiceIds.insert(choice.id)
        }
    }

    private func pinSelectedHomeTrip() {
        guard let destinationInfo = selectedTripDestination else {
            homePinStatusText = "Pick a destination first."
            homePinStatusIsError = true
            return
        }
        let trainChoices = selectedTrainChoices()
        let busChoices = selectedBusChoices()
        let metraChoices = selectedMetraChoices()
        let intercampusChoices = selectedIntercampusChoices()
        let option = bestHomeTripOption(
            trains: trainChoices,
            buses: busChoices,
            metras: metraChoices,
            intercampus: intercampusChoices
        ) ?? homeTripOptions.first
        let trains = trainChoices.map {
            PlannedTripPin.TrainLeg(
                line: $0.line,
                stationId: $0.stationId,
                stationName: $0.stationName,
                destinationName: $0.destinationName
            )
        }
        let buses = busChoices.map {
            PlannedTripPin.BusLeg(
                route: $0.route,
                stopId: $0.stopId,
                stopName: $0.stopName,
                directionLabel: $0.directionLabel
            )
        }
        let metras = metraChoices.map {
            PlannedTripPin.MetraLeg(
                routeId: $0.routeId,
                stationId: $0.stationId,
                stationName: $0.stationName,
                directionId: $0.directionId,
                destinationName: $0.destinationName
            )
        }
        let intercampus = intercampusChoices.map {
            PlannedTripPin.IntercampusLeg(
                direction: $0.direction,
                stopId: $0.stopId,
                stopName: $0.stopName,
                destinationName: $0.destinationName
            )
        }
        guard !trains.isEmpty || !buses.isEmpty || !metras.isEmpty || !intercampus.isEmpty else {
            homePinStatusText = "Pick at least one train, bus, Metra, or Intercampus leg."
            homePinStatusIsError = true
            return
        }
        let summary = homeTripTransitSummary(
            trains: trainChoices,
            buses: busChoices,
            metras: metraChoices,
            intercampus: intercampusChoices
        )
        let pin = PlannedTripPin(
            destination: destinationInfo,
            title: "Trip to \(destinationInfo.title)",
            summary: summary,
            expectedArrivalAt: option.map { Date().addingTimeInterval($0.expectedTravelTime) },
            expectedTravelTime: option?.expectedTravelTime ?? 0,
            allowMultimodal: true,
            includeDivvyInfo: includeDivvyInfoForTripPin,
            train: trains.first,
            bus: buses.first,
            metra: metras.first,
            trainLegs: trains,
            busLegs: buses,
            metraLegs: metras,
            intercampusLegs: intercampus
        )
        plannedTripPin = pin
        homeTripOptions = []
        homePinStatusText = nil
        homePinStatusIsError = false
        model.savePlannedTripPin(pin)
    }

    private func selectedTrainChoices() -> [HomeTripTrainChoice] {
        homeTripTrainChoices(in: homeTripOptions)
            .filter { selectedTrainChoiceIds.contains($0.id) }
    }

    private func selectedBusChoices() -> [HomeTripBusChoice] {
        homeTripBusChoices(in: homeTripOptions)
            .filter { selectedBusChoiceIds.contains($0.id) }
    }

    private func selectedMetraChoices() -> [HomeTripMetraChoice] {
        homeTripMetraChoices(in: homeTripOptions)
            .filter { selectedMetraChoiceIds.contains($0.id) }
    }

    private func selectedIntercampusChoices() -> [HomeTripIntercampusChoice] {
        homeTripIntercampusChoices(in: homeTripOptions)
            .filter { selectedIntercampusChoiceIds.contains($0.id) }
    }

    private func bestHomeTripOption(
        trains: [HomeTripTrainChoice],
        buses: [HomeTripBusChoice],
        metras: [HomeTripMetraChoice],
        intercampus: [HomeTripIntercampusChoice]
    ) -> HomeTripOption? {
        homeTripOptions
            .map { option in
                (
                    option: option,
                    score: homeTripOptionMatchScore(
                        option,
                        trains: trains,
                        buses: buses,
                        metras: metras,
                        intercampus: intercampus
                    )
                )
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.option.expectedTravelTime < $1.option.expectedTravelTime
            }
            .first?
            .option
    }

    private func homeTripOptionMatchScore(
        _ option: HomeTripOption,
        trains: [HomeTripTrainChoice],
        buses: [HomeTripBusChoice],
        metras: [HomeTripMetraChoice],
        intercampus: [HomeTripIntercampusChoice]
    ) -> Int {
        var score = 0
        for train in trains where option.trainChoices.contains(where: { trainPinKey($0) == trainPinKey(train) }) {
            score += 1
        }
        for bus in buses where option.busChoices.contains(where: { busPinKey($0) == busPinKey(bus) }) {
            score += 1
        }
        for metra in metras where option.metraChoices.contains(where: { metraPinKey($0) == metraPinKey(metra) }) {
            score += 1
        }
        for choice in intercampus
            where option.intercampusChoices.contains(where: { intercampusPinKey($0) == intercampusPinKey(choice) })
        {
            score += 1
        }
        return score
    }

    private func trainStationPinLabel(_ choice: HomeTripTrainChoice) -> String {
        guard let destinationName = choice.destinationName, !destinationName.isEmpty else {
            return choice.stationName
        }
        return "\(choice.stationName) → \(destinationName)"
    }

    private func busStopPinLabel(_ choice: HomeTripBusChoice) -> String {
        guard !choice.directionLabel.isEmpty else { return choice.stopName }
        return "\(choice.stopName) · \(choice.directionLabel)"
    }

    private func metraStationPinLabel(_ choice: HomeTripMetraChoice) -> String {
        guard let directionId = choice.directionId else { return choice.stationName }
        let direction = MetraDepartureGrouper.direction(
            for: directionId,
            destinationName: choice.destinationName ?? ""
        )
        return "\(choice.stationName) · \(direction.label)"
    }

    private func intercampusPinLabel(_ choice: HomeTripIntercampusChoice) -> String {
        "\(choice.stopName) · \(choice.direction.label)"
    }

    private func buildHomeTripOptions(
        from plans: [TripPlan],
        origin: PlannerCoordinate,
        destination: PlannerCoordinate
    ) -> [HomeTripOption] {
        let intercampusChoices = dedupeIntercampusChoices(intercampusChoicesForHomeTrip(
            origin: origin,
            destination: destination
        ))
        return plans.compactMap { plan -> HomeTripOption? in
            let transitLegs = plan.legs.enumerated().filter { $0.element.mode == .transit }
            guard !transitLegs.isEmpty else { return nil }

            var trainChoices: [HomeTripTrainChoice] = []
            var busChoices: [HomeTripBusChoice] = []
            var metraChoices: [HomeTripMetraChoice] = []

            for (index, leg) in transitLegs {
                guard let resolution = leg.transit?.resolution else { continue }
                switch resolution {
                case .line(let line):
                    guard isTrainLineDiscoverable(line) else { continue }
                    trainChoices.append(contentsOf: trainChoicesForHomeTrip(
                        line: line,
                        legIndex: index,
                        leg: leg,
                        fallbackOrigin: origin
                    ))
                case .bus(let route):
                    guard isBusRouteDiscoverable(route) else { continue }
                    busChoices.append(contentsOf: busChoicesForHomeTrip(
                        route: route,
                        legIndex: index,
                        leg: leg,
                        fallbackOrigin: origin
                    ))
                case .metra(let route):
                    guard isMetraRouteDiscoverable(route) else { continue }
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
            guard !dedupedTrains.isEmpty
                || !dedupedBuses.isEmpty
                || !dedupedMetra.isEmpty
                || !intercampusChoices.isEmpty
            else { return nil }
            let boardingAccess = homeTripBoardingAccess(
                plan: plan,
                transitLegs: transitLegs,
                trains: dedupedTrains,
                buses: dedupedBuses,
                metras: dedupedMetra,
                origin: origin
            )

            return HomeTripOption(
                title: homeTripTitle(plan: plan, transitLegCount: transitLegs.count),
                transitSummary: homeTripTransitSummary(
                    trains: dedupedTrains,
                    buses: dedupedBuses,
                    metras: dedupedMetra,
                    intercampus: intercampusChoices
                ),
                expectedTravelTime: plan.expectedTravelTime,
                totalDistanceMeters: plan.totalDistanceMeters,
                boardingAccess: boardingAccess,
                trainChoices: dedupedTrains,
                busChoices: dedupedBuses,
                metraChoices: dedupedMetra,
                intercampusChoices: intercampusChoices
            )
        }
    }

    private func homeTripBoardingAccess(
        plan: TripPlan,
        transitLegs: [(offset: Int, element: TripLeg)],
        trains: [HomeTripTrainChoice],
        buses: [HomeTripBusChoice],
        metras: [HomeTripMetraChoice],
        origin: PlannerCoordinate
    ) -> HomeTripBoardingAccess? {
        guard let firstTransit = transitLegs.min(by: { $0.offset < $1.offset }),
              let resolution = firstTransit.element.transit?.resolution
        else { return nil }

        let accessMeters = accessDistanceForTransitLeg(
            plan: plan,
            transitLegIndex: firstTransit.offset,
            origin: origin
        )

        switch resolution {
        case .line:
            guard let choice = trains.first(where: { $0.legIndex == firstTransit.offset }) else { return nil }
            return HomeTripBoardingAccess(
                kind: .train(stationId: choice.stationId),
                title: choice.stationName,
                destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: choice.stationId),
                directDistanceMeters: accessMeters
            )
        case .bus:
            guard let choice = buses.first(where: { $0.legIndex == firstTransit.offset }) else { return nil }
            return HomeTripBoardingAccess(
                kind: .bus(stopId: choice.stopId),
                title: choice.stopName,
                destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: choice.stopId),
                directDistanceMeters: accessMeters
            )
        case .metra:
            guard let choice = metras.first(where: { $0.legIndex == firstTransit.offset }) else { return nil }
            return HomeTripBoardingAccess(
                kind: .metra(stationId: choice.stationId),
                title: choice.stationName,
                destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: choice.stationId),
                directDistanceMeters: accessMeters
            )
        case .unknown:
            return nil
        }
    }

    private func accessDistanceForTransitLeg(
        plan: TripPlan,
        transitLegIndex: Int,
        origin: PlannerCoordinate
    ) -> Double {
        if transitLegIndex > plan.legs.startIndex {
            let previousLeg = plan.legs[plan.legs.index(before: transitLegIndex)]
            if previousLeg.mode == .walking {
                return previousLeg.distanceMeters
            }
        }
        guard let start = plan.legs[transitLegIndex].startCoordinate else { return 0 }
        return Distance.meters(
            from: (origin.latitude, origin.longitude),
            to: (start.latitude, start.longitude)
        )
    }

    private func homeTripBoardingAccessText(
        _ boardingAccess: HomeTripBoardingAccess,
        origin: (lat: Double, lon: Double)
    ) -> String {
        let summary = accessTimeSummary(
            origin: origin,
            destinationKey: boardingAccess.destinationKey,
            directDistanceMeters: boardingAccess.directDistanceMeters
        )
        return "\(AccessTimeFormatter.short(summary)) to \(boardingAccess.title)"
    }

    private func ensureHomeTripAccessRoutes(
        _ options: [HomeTripOption],
        origin: (lat: Double, lon: Double)
    ) {
        let accesses = options.compactMap(\.boardingAccess)
        let trainChoices = homeTripTrainChoices(in: options)
        let busChoices = homeTripBusChoices(in: options)
        let metraChoices = homeTripMetraChoices(in: options)
        let intercampusChoices = homeTripIntercampusChoices(in: options)
        let accessStationIds = Set(accesses.compactMap { access -> Int? in
            if case .train(stationId: let stationId) = access.kind { return stationId }
            return nil
        })
        let accessStopIds = Set(accesses.compactMap { access -> Int? in
            if case .bus(stopId: let stopId) = access.kind { return stopId }
            return nil
        })
        let accessMetraStationIds = Set(accesses.compactMap { access -> String? in
            if case .metra(stationId: let stationId) = access.kind { return stationId }
            return nil
        })
        let stationIds = accessStationIds.union(trainChoices.map(\.stationId))
        let stopIds = accessStopIds.union(busChoices.map(\.stopId))
        let metraStationIds = accessMetraStationIds.union(metraChoices.map(\.stationId))
        let intercampusStopIds = Set(intercampusChoices.map(\.stopId))

        let stations = LStationCatalog.all.filter { stationIds.contains($0.id) }
        let stops = BusStopCatalog.all.filter { stopIds.contains($0.id) }
        let metraStations = MetraStationCatalog.all.filter { metraStationIds.contains($0.id) }
        let intercampusStops = IntercampusCatalog.all.filter { intercampusStopIds.contains($0.id) }

        model.walkingResolver.ensureFresh(origin: origin, stations: stations)
        model.walkingResolver.ensureFresh(origin: origin, stops: stops)
        model.walkingResolver.ensureFresh(origin: origin, metraStations: metraStations)
        model.walkingResolver.ensureFresh(origin: origin, intercampusStops: intercampusStops)
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
                limit: 4,
                catalog: LStationCatalog.all,
                excludingStationIds: closedStationIds
            )
        return candidates.map { entry in
            HomeTripTrainChoice(
                line: line,
                stationId: entry.station.id,
                stationName: entry.station.name,
                destinationName: preferredTrainDestinationName(
                    line: line,
                    boardingStation: entry.station,
                    leg: leg
                ),
                distanceMeters: entry.distance,
                legIndex: legIndex
            )
        }
    }

    private func preferredTrainDestinationName(
        line: LineColor,
        boardingStation: LStation,
        leg: TripLeg
    ) -> String? {
        if let targetStation = closestTrainStation(line: line, coordinate: leg.endCoordinate),
           let projected = projectedTrainDestinationName(
               line: line,
               boardingStation: boardingStation,
               targetStation: targetStation
           ) {
            return projected
        }
        return trainDestinationName(fromInstruction: leg.instructions, line: line)
    }

    private func closestTrainStation(line: LineColor, coordinate: PlannerCoordinate?) -> LStation? {
        guard let coordinate else { return nil }
        return LStationCatalog.all
            .filter { $0.servedLines.contains(line) }
            .min {
                Distance.meters(
                    from: (coordinate.latitude, coordinate.longitude),
                    to: ($0.latitude, $0.longitude)
                ) < Distance.meters(
                    from: (coordinate.latitude, coordinate.longitude),
                    to: ($1.latitude, $1.longitude)
                )
            }
    }

    private func projectedTrainDestinationName(
        line: LineColor,
        boardingStation: LStation,
        targetStation: LStation
    ) -> String? {
        guard boardingStation.id != targetStation.id else {
            return trainDestinationName(for: targetStation, line: line)
        }

        let vector = trainProjectionVector(from: boardingStation, to: targetStation)
        let magnitudeSquared = vector.x * vector.x + vector.y * vector.y
        guard magnitudeSquared > 0.000001 else {
            return trainDestinationName(for: targetStation, line: line)
        }

        return LStationCatalog.all
            .filter { $0.servedLines.contains(line) && $0.id != boardingStation.id }
            .map { station -> (station: LStation, projection: Double) in
                let candidate = trainProjectionVector(from: boardingStation, to: station)
                return (
                    station: station,
                    projection: (candidate.x * vector.x + candidate.y * vector.y) / magnitudeSquared
                )
            }
            .filter { $0.projection >= 0.85 }
            .max { $0.projection < $1.projection }
            .flatMap { trainDestinationName(for: $0.station, line: line) }
    }

    private func trainProjectionVector(from origin: LStation, to destination: LStation) -> (x: Double, y: Double) {
        let midLatitude = ((origin.latitude + destination.latitude) / 2) * .pi / 180
        return (
            x: (destination.longitude - origin.longitude) * cos(midLatitude),
            y: destination.latitude - origin.latitude
        )
    }

    private func trainDestinationName(for station: LStation, line: LineColor) -> String? {
        if isLoopDestination(station, for: line) { return "Loop" }
        return station.name
    }

    private func isLoopDestination(_ station: LStation, for line: LineColor) -> Bool {
        switch line {
        case .brown, .orange, .pink, .purple:
            return [
                "Clark/Lake",
                "State/Lake",
                "Washington/Wabash",
                "Adams/Wabash",
                "Harold Washington Library-State/Van Buren",
                "LaSalle/Van Buren",
                "Quincy/Wells",
                "Washington/Wells"
            ].contains(station.name)
        case .red, .blue, .green, .yellow:
            return false
        }
    }

    private func trainDestinationName(fromInstruction instruction: String, line: LineColor) -> String? {
        guard let range = instruction.range(of: "toward ", options: .caseInsensitive)
            ?? instruction.range(of: "towards ", options: .caseInsensitive)
        else {
            return nil
        }
        let rawDestination = instruction[range.upperBound...]
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawDestination, !rawDestination.isEmpty else { return nil }
        let knownDestination = LStationCatalog.all
            .filter { $0.servedLines.contains(line) }
            .map(\.name)
            .first { $0.caseInsensitiveCompare(rawDestination) == .orderedSame }
        return knownDestination ?? rawDestination
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
            limit: 4,
            catalog: MetraStationCatalog.all
        )
        return candidates.map { entry in
            let directionId = preferredMetraDirectionId(
                route: route,
                boardingStation: entry.station,
                leg: leg
            )
            return HomeTripMetraChoice(
                routeId: route,
                stationId: entry.station.id,
                stationName: entry.station.name,
                directionId: directionId,
                destinationName: preferredMetraDestinationName(
                    route: route,
                    stationId: entry.station.id,
                    directionId: directionId
                ),
                distanceMeters: entry.distance,
                legIndex: legIndex
            )
        }
    }

    private func preferredMetraDirectionId(
        route: String,
        boardingStation: MetraStation,
        leg: TripLeg
    ) -> Int? {
        guard let targetStation = closestMetraStation(route: route, coordinate: leg.endCoordinate) else {
            return nil
        }
        return MetraStationCatalog.directionId(
            routeId: route,
            boardingStationId: boardingStation.id,
            targetStationId: targetStation.id
        )
    }

    private func closestMetraStation(route: String, coordinate: PlannerCoordinate?) -> MetraStation? {
        guard let coordinate else { return nil }
        return MetraStationCatalog.all
            .filter { $0.servedRoutes.contains(route) }
            .min {
                Distance.meters(
                    from: (coordinate.latitude, coordinate.longitude),
                    to: ($0.latitude, $0.longitude)
                ) < Distance.meters(
                    from: (coordinate.latitude, coordinate.longitude),
                    to: ($1.latitude, $1.longitude)
                )
            }
    }

    private func preferredMetraDestinationName(
        route: String,
        stationId: String,
        directionId: Int?
    ) -> String? {
        guard let directionId else { return nil }
        return MetraScheduleCatalog.upcomingDepartures(
            stationId: stationId,
            routeId: route,
            directionId: directionId,
            now: .now,
            horizon: 24 * 60 * 60,
            limit: 1
        )
        .first?
        .destinationName
    }

    private func intercampusChoicesForHomeTrip(
        origin: PlannerCoordinate,
        destination: PlannerCoordinate
    ) -> [HomeTripIntercampusChoice] {
        guard routePreferences.isModeVisible(.intercampus) else { return [] }
        let directions = preferredIntercampusDirections(origin: origin, destination: destination)
        let originPair = (lat: origin.latitude, lon: origin.longitude)
        return directions.flatMap { direction in
            intercampusStopResolver.closestStops(
                direction: direction,
                to: originPair,
                limit: 2,
                catalog: IntercampusCatalog.all
            )
            .map { entry in
                HomeTripIntercampusChoice(
                    direction: entry.direction,
                    stopId: entry.stop.id,
                    stopName: entry.stop.name,
                    destinationName: IntercampusCatalog.destinationName(for: entry.direction),
                    distanceMeters: entry.distance,
                    legIndex: 10_000
                )
            }
        }
    }

    private func preferredIntercampusDirections(
        origin: PlannerCoordinate,
        destination: PlannerCoordinate
    ) -> [IntercampusDirection] {
        let latitudeDelta = destination.latitude - origin.latitude
        guard abs(latitudeDelta) >= 0.005 else { return IntercampusDirection.allCases }
        return latitudeDelta < 0 ? [.southbound] : [.northbound]
    }

    private func dedupeTrainChoices(_ choices: [HomeTripTrainChoice]) -> [HomeTripTrainChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert(trainPinKey($0)).inserted }
    }

    private func dedupeBusChoices(_ choices: [HomeTripBusChoice]) -> [HomeTripBusChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert(busPinKey($0)).inserted }
    }

    private func dedupeMetraChoices(_ choices: [HomeTripMetraChoice]) -> [HomeTripMetraChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert(metraPinKey($0)).inserted }
    }

    private func dedupeIntercampusChoices(_ choices: [HomeTripIntercampusChoice]) -> [HomeTripIntercampusChoice] {
        var seen: Set<String> = []
        return choices.filter { seen.insert(intercampusPinKey($0)).inserted }
    }

    private func homeTripTrainChoices(in options: [HomeTripOption]) -> [HomeTripTrainChoice] {
        var choices: [HomeTripTrainChoice] = []
        var indexByKey: [String: Int] = [:]
        for choice in options.flatMap(\.trainChoices) {
            let key = trainPinKey(choice)
            if let index = indexByKey[key] {
                if choices[index].destinationName == nil, choice.destinationName != nil {
                    choices[index] = choice
                }
                continue
            }
            indexByKey[key] = choices.count
            choices.append(choice)
        }
        return choices
    }

    private func homeTripBusChoices(in options: [HomeTripOption]) -> [HomeTripBusChoice] {
        var seen: Set<String> = []
        return options.flatMap(\.busChoices).filter { seen.insert(busPinKey($0)).inserted }
    }

    private func homeTripMetraChoices(in options: [HomeTripOption]) -> [HomeTripMetraChoice] {
        var seen: Set<String> = []
        return options.flatMap(\.metraChoices).filter { seen.insert(metraPinKey($0)).inserted }
    }

    private func homeTripIntercampusChoices(in options: [HomeTripOption]) -> [HomeTripIntercampusChoice] {
        var seen: Set<String> = []
        return options.flatMap(\.intercampusChoices).filter { seen.insert(intercampusPinKey($0)).inserted }
    }

    private func homeTripTrainLines(in options: [HomeTripOption]) -> [LineColor] {
        var seen: Set<LineColor> = []
        return homeTripTrainChoices(in: options)
            .map(\.line)
            .filter { seen.insert($0).inserted }
    }

    private func homeTripBusRoutes(in options: [HomeTripOption]) -> [String] {
        var seen: Set<String> = []
        return homeTripBusChoices(in: options)
            .map(\.route)
            .filter { seen.insert($0).inserted }
    }

    private func homeTripMetraRoutes(in options: [HomeTripOption]) -> [String] {
        var seen: Set<String> = []
        return homeTripMetraChoices(in: options)
            .map(\.routeId)
            .filter { seen.insert($0).inserted }
    }

    private func trainPinKey(_ choice: HomeTripTrainChoice) -> String {
        "\(choice.line.rawValue)-\(choice.stationId)"
    }

    private func busPinKey(_ choice: HomeTripBusChoice) -> String {
        "\(choice.route)-\(choice.stopId)"
    }

    private func metraPinKey(_ choice: HomeTripMetraChoice) -> String {
        "\(choice.routeId)-\(choice.stationId)-\(choice.directionId.map(String.init) ?? "any")"
    }

    private func intercampusPinKey(_ choice: HomeTripIntercampusChoice) -> String {
        "\(choice.direction.rawValue)-\(choice.stopId)"
    }

    private func homeTripTitle(plan: TripPlan, transitLegCount: Int) -> String {
        if let summary = cleanedTripSummary(plan.summary) {
            switch plan.flavor {
            case .standard:
                return summary
            case .train, .busShortestRide, .busShortestWalk, .busToTrain, .busToBus, .trainToBus, .multiTransfer, .metra:
                return summary
            }
        }
        if transitLegCount > 1 { return "Multimodal route" }
        switch plan.flavor {
        case .train: return "Train route"
        case .metra: return "Metra route"
        case .busToTrain: return "Bus + train route"
        case .busToBus: return "Bus + bus route"
        case .trainToBus: return "Train + bus route"
        case .multiTransfer: return "Transfer route"
        case .busShortestRide: return "Bus route"
        case .busShortestWalk: return "Low-walk bus route"
        case .standard: return "Transit route"
        }
    }

    private func cleanedTripSummary(_ summary: String) -> String? {
        let cleaned = summary
            .replacingOccurrences(of: " · estimated", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func homeTripTransitSummary(
        trains: [HomeTripTrainChoice],
        buses: [HomeTripBusChoice],
        metras: [HomeTripMetraChoice],
        intercampus: [HomeTripIntercampusChoice] = []
    ) -> String {
        let trainPieces = trains.map { (legIndex: $0.legIndex, label: $0.line.displayName) }
        let busPieces = buses.map { (legIndex: $0.legIndex, label: "Route \($0.route)") }
        let metraPieces = metras.map {
            (
                legIndex: $0.legIndex,
                label: "Metra \(MetraStationCatalog.route(id: $0.routeId)?.shortName ?? $0.routeId)"
            )
        }
        let intercampusPieces = intercampus.map {
            (legIndex: $0.legIndex, label: "Intercampus")
        }
        var seen: Set<String> = []
        let pieces = (trainPieces + busPieces + metraPieces + intercampusPieces)
            .sorted { $0.legIndex < $1.legIndex }
            .map(\.label)
            .filter { seen.insert($0).inserted }
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

    // MARK: - Live updates toggle

    private var liveUpdatesBar: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Circle()
                .fill(liveStatusDotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("Live updates")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
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
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.sm)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var liveStatusDotColor: Color {
        if model.isLowPowerMode { return ChicagoPalette.gold }
        return model.liveUpdatesEnabled ? ChicagoPalette.green : ChicagoPalette.Gray.light
    }

    private var liveStatusDescription: String {
        if model.isLowPowerMode {
            return "Paused by Low Power Mode"
        }
        if model.liveUpdatesEnabled {
            return shouldShowIntercampusSurface
                ? "CTA, Metra, Intercampus · 30s"
                : "CTA, Metra · 30s"
        }
        return "Manual refresh"
    }

    // MARK: - Context banner

    private var contextBanner: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Image(systemName: "location.north.line.fill")
                .foregroundStyle(ChicagoPalette.flagBlue)
            Text("Autopin")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.bahama)
            Text(autopinDescription)
                .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(1)
            Spacer()
            if model.isRefreshing { ProgressView().scaleEffect(0.7) }
        }
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.sm)
        .background(ChicagoPalette.Surface.elevated,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var shouldShowAutopinBanner: Bool {
        isAutopinned
    }

    private var autopinDescription: String {
        switch autoPinnedDirection {
        case .toHome:
            return "Route home"
        case .toWork:
            return "Route to work"
        case .anytime, nil:
            return "Commute route"
        }
    }

    private var isAutopinned: Bool {
        pinSource == .automatic && (pinnedLine != nil || pinnedBusRoute != nil || pinnedMetraRoute != nil)
    }

    // MARK: - Northwestern Intercampus

    private var intercampusCard: some View {
        ChicagoCard(title: "Intercampus",
                    eyebrow: "Northwestern",
                    ornament: .icon(systemName: "bus.fill"),
                    accent: ChicagoPalette.Mode.intercampus) {
            intercampusBody
        }
    }

    @ViewBuilder
    private var intercampusBody: some View {
        if let origin {
            let candidateEntries = intercampusCandidateEntries(origin: origin)
            let directionChoices = intercampusDirectionChoices(
                from: candidateEntries,
                origin: origin
            )
            if directionChoices.isEmpty {
                Text("No Intercampus stops within 2 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                let activeDirection = effectiveIntercampusDirection(in: directionChoices)
                let activeChoice = directionChoices.first { $0.direction == activeDirection }
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    directionPickerForIntercampus(choices: directionChoices)
                    if let activeChoice {
                        let hasWalkingData = activeChoice.stops.contains {
                            $0.walkingDistanceMeters != nil
                        }
                        if hasWalkingData || allowIntercampusHaversineFallback {
                            intercampusStopSelector(choice: activeChoice)
                            let selected = effectivePinnedIntercampusStop(in: activeChoice)
                            intercampusStopRow(choice: selected)
                        } else {
                            placeholderChipStrip
                        }
                    }
                }
                .task(id: intercampusWalkingTaskKey(origin: origin)) {
                    allowIntercampusHaversineFallback = false
                    model.walkingResolver.ensureFresh(
                        origin: origin,
                        intercampusStops: Array(Set(candidateEntries.map(\.stop)))
                    )
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        allowIntercampusHaversineFallback = true
                    } catch {
                        // Cancelled because the origin changed.
                    }
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    private func intercampusCandidateEntries(
        origin: (lat: Double, lon: Double)
    ) -> [NearestIntercampusStopResolver.Entry] {
        var entries = intercampusStopResolver.nearestPerDirection(
            to: origin,
            limitPerDirection: 12,
            catalog: IntercampusCatalog.all
        )
        if let selectedStopId = pinnedIntercampusStopId,
           let selectedStop = IntercampusCatalog.stop(id: selectedStopId)
        {
            let directions = pinnedIntercampusDirection.map { [$0] } ?? selectedStop.servedDirections
            for direction in directions where selectedStop.servedDirections.contains(direction) {
                let distance = Distance.meters(
                    from: origin,
                    to: (selectedStop.latitude, selectedStop.longitude)
                )
                entries.append(NearestIntercampusStopResolver.Entry(
                    direction: direction,
                    stop: selectedStop,
                    distance: distance
                ))
            }
        }
        for leg in plannedTripPin?.intercampusLegs ?? [] {
            guard let stop = IntercampusCatalog.stop(id: leg.stopId),
                  stop.servedDirections.contains(leg.direction)
            else { continue }
            let distance = Distance.meters(
                from: origin,
                to: (stop.latitude, stop.longitude)
            )
            entries.append(NearestIntercampusStopResolver.Entry(
                direction: leg.direction,
                stop: stop,
                distance: distance
            ))
        }

        var seen: Set<String> = []
        return entries.filter { entry in
            seen.insert(entry.id).inserted
        }
    }

    private func intercampusDirectionChoices(
        from entries: [NearestIntercampusStopResolver.Entry],
        origin: (lat: Double, lon: Double)
    ) -> [IntercampusDirectionStopChoice] {
        IntercampusDirection.allCases.compactMap { direction -> IntercampusDirectionStopChoice? in
            let candidates = entries.filter { $0.direction == direction }
            guard !candidates.isEmpty else { return nil }

            let ranked = rankIntercampusStopsWithWalking(
                candidates: candidates,
                origin: origin
            )
            let visible = Array(
                StationAccessRanker()
                    .visibleAccessCandidates(from: ranked)
                    .prefix(3)
            )
            var choices = visible.map { ranked in
                IntercampusStopChoice(
                    direction: direction,
                    stop: ranked.item,
                    directDistanceMeters: ranked.directDistanceMeters,
                    walkingDistanceMeters: ranked.walkingDistanceMeters,
                    accessDistanceMeters: ranked.accessDistanceMeters,
                    displayTravelTime: ranked.displayTravelTime,
                    isApproximateTravelTime: ranked.isApproximateTravelTime
                )
            }

            if let pinnedIntercampusStopId,
               pinnedIntercampusDirection == direction,
               choices.contains(where: { $0.stop.id == pinnedIntercampusStopId }) == false,
               let pinned = ranked.first(where: { $0.item.id == pinnedIntercampusStopId })
            {
                choices.append(IntercampusStopChoice(
                    direction: direction,
                    stop: pinned.item,
                    directDistanceMeters: pinned.directDistanceMeters,
                    walkingDistanceMeters: pinned.walkingDistanceMeters,
                    accessDistanceMeters: pinned.accessDistanceMeters,
                    displayTravelTime: pinned.displayTravelTime,
                    isApproximateTravelTime: pinned.isApproximateTravelTime
                ))
            }

            guard !choices.isEmpty else { return nil }
            return IntercampusDirectionStopChoice(
                direction: direction,
                stops: choices.sorted { $0.accessDistanceMeters < $1.accessDistanceMeters }
            )
        }
        .sorted {
            ($0.stops.first?.accessDistanceMeters ?? .infinity)
                < ($1.stops.first?.accessDistanceMeters ?? .infinity)
        }
    }

    private func rankIntercampusStopsWithWalking(
        candidates: [NearestIntercampusStopResolver.Entry],
        origin: (lat: Double, lon: Double)
    ) -> [StationAccessRanker.RankedAccessCandidate<IntercampusStop>] {
        let ranker = StationAccessRanker()
        return ranker.rank(candidates.map { entry in
            let walking = model.walkingResolver.cached(
                origin: origin,
                intercampusStop: entry.stop
            ) ?? model.walkingResolver.staleFallback(
                origin: origin,
                intercampusStop: entry.stop
            )
            return StationAccessRanker.AccessCandidate(
                item: entry.stop,
                directDistanceMeters: entry.distance,
                walkingDistanceMeters: walking?.meters,
                walkingTravelTime: walking?.expectedTravelTime
            )
        })
    }

    private func effectiveIntercampusDirection(
        in choices: [IntercampusDirectionStopChoice]
    ) -> IntercampusDirection {
        if let direction = pinnedIntercampusDirection,
           choices.contains(where: { $0.direction == direction })
        {
            return direction
        }
        return choices.first?.direction ?? .northbound
    }

    private func directionPickerForIntercampus(
        choices: [IntercampusDirectionStopChoice]
    ) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a direction")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ChicagoSpacing.xs) {
                    ForEach(choices) { choice in
                        DirectionChip(
                            label: choice.direction.label,
                            isSelected: effectiveIntercampusDirection(in: choices) == choice.direction,
                            accent: intercampusAccent,
                            action: { setPinnedIntercampusDirection(choice.direction) }
                        )
                    }
                }
            }
        }
    }

    private func intercampusStopSelector(choice: IntercampusDirectionStopChoice) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a stop")
            StationChipStrip {
                ForEach(choice.stops) { entry in
                    IntercampusStopChip(
                        choice: entry,
                        isSelected: entry.stop.id == effectivePinnedIntercampusStop(in: choice).stop.id,
                        accent: intercampusAccent,
                        action: { setPinnedIntercampusStop(entry) }
                    )
                }
            }
        }
    }

    private func effectivePinnedIntercampusStop(
        in choice: IntercampusDirectionStopChoice
    ) -> IntercampusStopChoice {
        if let id = pinnedIntercampusStopId,
           let selected = choice.stops.first(where: { $0.stop.id == id })
        {
            return selected
        }
        return choice.stops.first!
    }

    private func intercampusStopRow(choice: IntercampusStopChoice) -> some View {
        let arrivals = intercampusArrivals(direction: choice.direction, stop: choice.stop)
        let first = arrivals.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(choice.stop.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(intercampusAccent)
                Spacer()
                Text(choice.walkTimeText)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            Text(choice.direction.label)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.light)
            if arrivals.isEmpty {
                Text(model.isRefreshing
                     ? "Fetching Intercampus arrivals…"
                     : "No upcoming Intercampus arrivals returned by TripShot.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else if let minutes, let first {
                HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                    BigNumber(
                        minutes,
                        unit: "min",
                        size: .md,
                        tone: first.isDelayed ? .alert : .primary,
                        accessibilityLabel: "\(minutes) minutes to next Intercampus shuttle, \(first.timeSource.label.lowercased()) time"
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: ChicagoSpacing.xs) {
                            Text("→ \(first.destinationName)")
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                                .foregroundStyle(ChicagoPalette.Gray.medium)
                                .lineLimit(1)
                            intercampusTimeSourceBadge(first.timeSource)
                        }
                        if let vehicleLabel = first.vehicleLabel, !vehicleLabel.isEmpty {
                            Text("Bus \(vehicleLabel)")
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.Gray.light)
                                .lineLimit(1)
                        }
                    }
                }
                HeadwayDotStrip(
                    arrivals: arrivals.prefix(8).map(\.arrivalAt),
                    accent: intercampusAccent
                )
            }
        }
    }

    private func intercampusTimeSourceBadge(_ source: IntercampusArrivalTimeSource) -> some View {
        let isLive = source == .liveMap
        return Text(source.label)
            .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
            .foregroundStyle(isLive ? intercampusAccent : ChicagoPalette.Gray.medium)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (isLive ? intercampusAccent.opacity(0.14) : ChicagoPalette.Gray.light.opacity(0.16)),
                in: Capsule()
            )
            .accessibilityLabel(source == .liveMap ? "Live map time" : "Schedule time")
    }

    private func intercampusArrivals(
        direction: IntercampusDirection,
        stop: IntercampusStop
    ) -> [IntercampusArrival] {
        model.snapshot.intercampusArrivals
            .filter { $0.direction == direction && $0.stopId == stop.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
    }

    private func setPinnedIntercampusDirection(_ direction: IntercampusDirection) {
        let changed = pinnedIntercampusDirection != direction
        pinnedIntercampusDirection = direction
        if changed {
            pinnedIntercampusStopId = nil
        }
        model.saveIntercampusPreferences {
            $0.pinnedIntercampusDirection = direction
            if changed {
                $0.pinnedIntercampusStopId = nil
            }
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedIntercampusStop(_ choice: IntercampusStopChoice) {
        pinnedIntercampusDirection = choice.direction
        pinnedIntercampusStopId = choice.stop.id
        model.saveIntercampusPreferences {
            $0.pinnedIntercampusDirection = choice.direction
            $0.pinnedIntercampusStopId = choice.stop.id
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func intercampusWalkingTaskKey(origin: (lat: Double, lon: Double)) -> String {
        let lat = (origin.lat * 11000).rounded()
        let lon = (origin.lon * 11000).rounded()
        return "intercampus:\(lat):\(lon)"
    }

    private var intercampusAccent: Color {
        ChicagoPalette.Mode.intercampus
    }

    // MARK: - Train line picker

    private var linePickerCard: some View {
        ChicagoCard(title: "Pin an L line",
                    eyebrow: "Trains",
                    ornament: .icon(systemName: "tram.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                if let line = visiblePinnedLine {
                    pickerPinnedConfirmationRow(
                        title: line.displayName,
                        clearLabel: "Clear pinned \(line.displayName) line",
                        clearAction: { togglePinnedLine(line) }
                    ) {
                        RouteBadge(line: line, size: .sm)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ForEach(linePickerLines, id: \.self) { line in
                            LineChip(
                                line: line,
                                isPinned: pinnedLine == line,
                                action: { togglePinnedLine(line) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var visiblePinnedLine: LineColor? {
        guard let pinnedLine, isTrainLineDiscoverable(pinnedLine) else { return nil }
        return pinnedLine
    }

    private var linePickerLines: [LineColor] {
        LineColor.allCases.filter { isTrainLineDiscoverable($0) }
    }

    private func pinnedLineCard(line: LineColor) -> some View {
        ChicagoCard(title: "Pinned train",
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
                    pinnedRouteControlRow(
                        title: line.displayName,
                        detail: "Pinned train",
                        alerts: alerts(forLine: line),
                        clearLabel: "Clear pinned \(line.displayName) line",
                        clearAction: { togglePinnedLine(line) }
                    ) {
                        RouteBadge(line: line, size: .md)
                    }
                    if hasWalkingData || allowHaversineFallback {
                        if let chosen = stations.first(where: { $0.station.id == chosenId }) {
                            let destinationChoices = trainDestinationGroups(at: chosen.station, line: line)
                                .flatMap(\.destinations)
                            Group {
                                arrivalsHeadline(at: chosen.station, line: line)
                                directionPickerForTrain(at: chosen.station, line: line)
                                trainProgressStrip(toStation: chosen.station, line: line)
                            }
                            .task(id: trainDirectionDefaultTaskKey(
                                line: line,
                                stationId: chosen.station.id,
                                destinations: destinationChoices
                            )) {
                                applyDefaultPinnedTrainDestinationIfNeeded(
                                    line: line,
                                    availableDestinations: destinationChoices
                                )
                            }
                        }
                        sectionLabel("Stop")
                        StationChipStrip {
                            ForEach(stations, id: \.station.id) { entry in
                                StationChip(
                                    station: entry.station,
                                    accessTime: stationAccessSummary(entry: entry, origin: origin),
                                    isSelected: entry.station.id == chosenId,
                                    accent: line.swiftUIColor,
                                    action: { setPinnedStation(entry.station.id) }
                                )
                            }
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
                            arrivalsHeadline(at: stuck, line: line)
                            directionPickerForTrain(at: stuck, line: line)
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
                        try await Task.sleep(for: .seconds(2))
                        if let selected = candidates.first(where: { $0.station.id == chosenId })?.station {
                            model.walkingResolver.ensureFresh(
                                origin: origin,
                                station: selected,
                                modes: [.cycling]
                            )
                        }
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

    private func accessTaskKey(prefix: String, origin: (lat: Double, lon: Double)) -> String {
        // ~10m grid: enough precision to retrigger when the user actually
        // moves, coarse enough to avoid GPS-jitter thrashes mid-render.
        let lat = (origin.lat * 11000).rounded()
        let lon = (origin.lon * 11000).rounded()
        return "\(prefix):\(lat):\(lon)"
    }

    private func stationAccessSummary(
        entry: StationAccessRanker.RankedCandidate,
        origin: (lat: Double, lon: Double)
    ) -> AccessTimeSummary {
        let cycling = cachedAccessRoute(
            origin: origin,
            destinationKey: WalkingDistanceStore.stationDestinationKey(stationId: entry.station.id),
            mode: .cycling
        )
        return AccessTimeSummary(
            walkingTravelTime: entry.displayTravelTime,
            isApproximateWalkingTime: entry.isApproximateTravelTime,
            cyclingTravelTime: cycling?.expectedTravelTime
                ?? AccessTimeFormatter.approximateCyclingTravelTime(distanceMeters: entry.accessDistanceMeters)
        )
    }

    private func accessTimeSummary(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        directDistanceMeters: Double
    ) -> AccessTimeSummary {
        let walking = cachedAccessRoute(
            origin: origin,
            destinationKey: destinationKey,
            mode: .walking
        )
        let cycling = cachedAccessRoute(
            origin: origin,
            destinationKey: destinationKey,
            mode: .cycling
        )
        return AccessTimeSummary(
            walkingTravelTime: walking?.expectedTravelTime
                ?? AccessTimeFormatter.approximateWalkingTravelTime(distanceMeters: directDistanceMeters),
            isApproximateWalkingTime: walking == nil,
            cyclingTravelTime: cycling?.expectedTravelTime
                ?? AccessTimeFormatter.approximateCyclingTravelTime(distanceMeters: directDistanceMeters)
        )
    }

    private func cachedAccessRoute(
        origin: (lat: Double, lon: Double),
        destinationKey: String,
        mode: AccessTravelMode
    ) -> WalkingDistance? {
        model.walkingResolver.cached(
            origin: origin,
            destinationKey: destinationKey,
            mode: mode
        ) ?? model.walkingResolver.staleFallback(
            origin: origin,
            destinationKey: destinationKey,
            mode: mode
        )
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
        let groups = trainDestinationGroups(at: station, line: line)
        // Always show the picker when there's more than one destination
        // anywhere at the station, even if those destinations sit in the
        // same direction group. The multi-select grouping IS the feature:
        // the user can keep Forest Park + UIC-Halsted both lit, or drop
        // one.
        let allDestinations = groups.flatMap(\.destinations)
        if allDestinations.count > 1 {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Pick a direction")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.md) {
                        ForEach(groups, id: \.directionCode) { group in
                            HStack(spacing: ChicagoSpacing.xs) {
                                ForEach(group.destinations, id: \.self) { dest in
                                    DirectionChip(
                                        label: "→ \(dest)",
                                        isSelected: isPinnedDestinationSelected(dest),
                                        accent: line.swiftUIColor,
                                        action: { togglePinnedTrainDestination(dest) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Destinations bucketed by `Arrival.directionCode` — the natural
    /// "same physical direction" key. CTA gives Forest Park and
    /// UIC-Halsted the same directionCode because they share the
    /// southwest branch of the Blue Line; Howard and 95th/Dan Ryan get
    /// different codes because they're physically opposite directions
    /// on the Red Line. The UI renders chips inside a group side-by-side
    /// with breathing room between groups so the visual structure
    /// matches the physical structure.
    private func trainDestinationGroups(
        at station: LStation,
        line: LineColor
    ) -> [(directionCode: String, destinations: [String])] {
        let arrivalsAtStation = model.snapshot.trainArrivals
            .filter { $0.line == line && $0.stationId == station.id }
        // Build directionCode → ordered unique destinations, where the
        // order within a group reflects soonest-next-arrival (so the
        // most relevant destination in each direction sorts left).
        var groups: [(code: String, soonest: Date, destinations: [String])] = []
        let byCode = Dictionary(grouping: arrivalsAtStation, by: \.directionCode)
        for (code, arrivalsInCode) in byCode {
            let destinationsByName = Dictionary(grouping: arrivalsInCode, by: \.destinationName)
            let destinations = destinationsByName
                .sorted { lhs, rhs in
                    let l = lhs.value.map(\.arrivalAt).min() ?? .distantFuture
                    let r = rhs.value.map(\.arrivalAt).min() ?? .distantFuture
                    return l < r
                }
                .map(\.key)
            let soonest = arrivalsInCode.map(\.arrivalAt).min() ?? .distantFuture
            groups.append((code: code, soonest: soonest, destinations: destinations))
        }
        // Order the groups by soonest arrival in each — the direction
        // with imminent service sorts first.
        return groups
            .sorted { $0.soonest < $1.soonest }
            .map { (directionCode: $0.code, destinations: $0.destinations) }
    }

    /// Selection state for a destination chip. `pinnedTrainDestinations`
    /// nil ⇒ no filter applied ⇒ ALL destinations are visually
    /// "unselected" (the strip shows everything, but the chips
    /// themselves are outlined). Non-nil ⇒ `contains` test.
    private func isPinnedDestinationSelected(_ destination: String) -> Bool {
        guard let set = pinnedTrainDestinations else { return false }
        return set.contains(destination)
    }

    private func trainDirectionDefaultTaskKey(
        line: LineColor,
        stationId: Int,
        destinations: [String]
    ) -> String {
        [
            line.rawValue,
            String(stationId),
            pinnedTrainDestinations?.sorted().joined(separator: "+") ?? "none",
            destinations.joined(separator: "|")
        ].joined(separator: ":")
    }

    @MainActor
    private func applyDefaultPinnedTrainDestinationIfNeeded(
        line: LineColor,
        availableDestinations: [String]
    ) {
        guard pinSource == .manual,
              pinnedLine == line,
              pinnedTrainDestinations == nil,
              availableDestinations.count > 1,
              let primary = defaultTrainDestination(
                  line: line,
                  availableDestinations: availableDestinations
              )
        else { return }

        // Default: pre-select every destination that shares the
        // primary destination's directionCode. So if the resolver
        // picks "Forest Park" as the user's commute-bound choice
        // and UIC-Halsted shares the same direction, both light up
        // by default. The user can deselect either to narrow.
        let stationId = pinnedStationId
        let destinations: [String] = {
            guard let stationId else { return [primary] }
            let arrivalsAtStation = model.snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == stationId }
            guard let primaryArrival = arrivalsAtStation.first(where: {
                $0.destinationName == primary
            }) else { return [primary] }
            let sameDirection = arrivalsAtStation
                .filter { $0.directionCode == primaryArrival.directionCode }
                .map(\.destinationName)
            // De-dupe preserving deterministic order.
            var seen: Set<String> = []
            return sameDirection.filter { seen.insert($0).inserted }
        }()

        pinnedTrainDestinations = destinations
        model.saveManualRoutePreferences {
            $0.pinnedTrainDestinations = destinations
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func defaultTrainDestination(
        line: LineColor,
        availableDestinations: [String]
    ) -> String? {
        PinnedLineDefaultResolver().preferredTrainDestination(
            line: line,
            availableDestinations: availableDestinations,
            preferences: routePreferences,
            profile: model.preferences.loadMobilityProfile(),
            context: model.location.context,
            location: model.location.lastKnown
        )
    }

    private func trainDestinationLabelsForPinnedLine(_ line: LineColor) -> [String] {
        guard let origin,
              let station = NearestStationResolver(maxDistanceMeters: 10_000)
                .closestStations(
                    onLine: line,
                    to: origin,
                    limit: 1,
                    catalog: LStationCatalog.all,
                    excludingStationIds: closedStationIds
                )
                .first?
                .station
        else { return [] }
        return trainDestinationGroups(at: station, line: line).flatMap(\.destinations)
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
            if let pinned = pinnedTrainDestinations {
                return base.filter { pinned.contains($0.destinationName) }
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
            // Collapse arrivals into one headline per direction-of-travel.
            // CTA gives Forest Park and UIC-Halsted the same
            // `directionCode` because they share the Blue Line's
            // southwest branch — when the user has both selected (the
            // default), the dashboard shows ONE headline for the
            // group with a combined next-arrival number, a single
            // bias-corrected dot strip, and the destination label
            // listing both names ("→ Forest Park / UIC-Halsted"). If
            // they've narrowed to one, the label degrades cleanly to
            // just that destination.
            let grouped = Dictionary(grouping: arrivals, by: \.directionCode)
                .sorted { ($0.value.first?.arrivalAt ?? .distantFuture)
                          < ($1.value.first?.arrivalAt ?? .distantFuture) }
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                ForEach(grouped, id: \.key) { _, times in
                    let sortedTimes = times.sorted(by: { $0.arrivalAt < $1.arrivalAt })
                    let first = sortedTimes.first!
                    let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(.now) / 60).rounded()))
                    let assessments = ghostAssessments(for: sortedTimes)
                    let firstAssessment = assessments[first.id]
                    let isGhostLikely = firstAssessment?.isGhostLikely == true
                    let biasCorrection = headlineBiasCorrection(for: sortedTimes)
                    let bunching = bunchingHint(for: sortedTimes)
                    // Destination label: every unique destination in
                    // this direction, ordered by soonest arrival, joined
                    // with " / ".
                    let destinationsInOrder: [String] = {
                        var seen: Set<String> = []
                        return sortedTimes.map(\.destinationName).filter {
                            seen.insert($0).inserted
                        }
                    }()
                    let destinationLabel = destinationsInOrder.joined(separator: " / ")
                    VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                        Text("→ \(destinationLabel)")
                            .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                            .foregroundStyle(ChicagoPalette.bahama)
                        HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.sm) {
                            BigNumber(
                                minutes,
                                unit: "min",
                                size: .lg,
                                tone: first.isDelayed || isGhostLikely ? .alert : .primary,
                                accessibilityLabel: "\(minutes) minutes to next \(destinationLabel) train"
                            )
                            if first.isDelayed || isGhostLikely {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(ChicagoPalette.starRed)
                                    .accessibilityLabel(isGhostLikely ? "Likely ghost train" : "Delayed")
                            }
                        }
                        if let badge = GhostTrainBadge(firstAssessment) {
                            badge
                        }
                        if let biasCorrection {
                            Text(biasCorrection.displayText)
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.Gray.medium)
                                .lineLimit(1)
                                .accessibilityLabel(biasCorrection.accessibilityLabel)
                        }
                        if let bunching {
                            Text("+ another in \(bunching.minutes)m")
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.Gray.medium)
                                .lineLimit(1)
                                .accessibilityLabel("Another \(destinationLabel) train in \(bunching.minutes) minutes")
                        }
                        HeadwayDotStrip(
                            arrivals: sortedTimes.prefix(8).map(\.arrivalAt),
                            accent: line.swiftUIColor,
                            complications: ghostComplications(
                                for: sortedTimes.prefix(8),
                                assessments: assessments
                            ),
                            urgencies: departureUrgencies(
                                forStationId: first.stationId,
                                arrivals: sortedTimes.prefix(8)
                            )
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
        let defaultDestination = newValue.map {
            defaultTrainDestination(
                line: $0,
                availableDestinations: trainDestinationLabelsForPinnedLine($0)
            )
        } ?? nil
        pinnedLine = newValue
        pinnedStationId = nil
        // Defer to applyDefaultPinnedTrainDestinationIfNeeded once the
        // station is set — that's the only point where we know which
        // direction code to default into. Until then, leave it nil.
        let defaultDestinations: [String]? = defaultDestination.map { [$0] }
        pinnedTrainDestinations = defaultDestinations
        model.saveManualRoutePreferences {
            $0.pinnedLine = newValue
            $0.pinnedStationId = nil
            $0.pinnedTrainDestinations = defaultDestinations
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedStation(_ id: Int) {
        pinnedStationId = id
        pinnedTrainDestinations = nil
        model.saveManualRoutePreferences {
            $0.pinnedStationId = id
            $0.pinnedTrainDestinations = nil
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
            .filter { pinnedTrainDestinations?.contains($0.destinationName) ?? true }
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
                        if let pinned = pinnedTrainDestinations { return Set(pinned) }
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
                accent: ChicagoPalette.Mode.bus,
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

    /// Toggle a single destination in the pinned-destinations set.
    /// Three transitions:
    /// - nil (show-all) → tapping a chip starts a new explicit
    ///   filter set containing just that destination.
    /// - non-nil, chip not in set → add it.
    /// - non-nil, chip already in set → remove it. If the set
    ///   becomes empty, drop back to nil so the dashboard's filter
    ///   reverts to "show all" rather than "show nothing."
    private func togglePinnedTrainDestination(_ destination: String) {
        var newValue: [String]?
        if var current = pinnedTrainDestinations {
            if current.contains(destination) {
                current.removeAll(where: { $0 == destination })
                newValue = current.isEmpty ? nil : current
            } else {
                current.append(destination)
                newValue = current
            }
        } else {
            newValue = [destination]
        }
        pinnedTrainDestinations = newValue
        model.saveManualRoutePreferences {
            $0.pinnedTrainDestinations = newValue
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bus route picker

    private var busRoutePickerCard: some View {
        ChicagoCard(title: "Pin a bus route",
                    eyebrow: "Buses",
                    ornament: .icon(systemName: "bus.fill"),
                    accent: ChicagoPalette.Mode.bus) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                if let route = visiblePinnedBusRoute {
                    pickerPinnedConfirmationRow(
                        title: "Route \(route)",
                        clearLabel: "Clear pinned Route \(route)",
                        clearAction: { setPinnedBus(nil) }
                    ) {
                        RouteBadge(bus: route, size: .sm)
                    }
                }
                Menu {
                    if visiblePinnedBusRoute != nil {
                        Button("Unpin", role: .destructive) { setPinnedBus(nil) }
                        Divider()
                    }
                    let nearby = nearbyBusRoutesForPicker
                    if !nearby.isEmpty {
                        Section("Nearby") {
                            ForEach(nearby) { entry in
                                Button("Route \(entry.route) — \(DistanceFormatter.short(entry.distanceMeters))") {
                                    setPinnedBus(entry.route)
                                }
                            }
                        }
                        Section("All routes") {
                            ForEach(busPickerRoutes, id: \.self) { route in
                                Button("Route \(route)") { setPinnedBus(route) }
                            }
                        }
                    } else {
                        ForEach(busPickerRoutes, id: \.self) { route in
                            Button("Route \(route)") { setPinnedBus(route) }
                        }
                    }
                } label: {
                    HStack(spacing: ChicagoSpacing.xs) {
                        Image(systemName: "bus.fill")
                            .foregroundStyle(ChicagoPalette.Mode.bus)
                        Text(visiblePinnedBusRoute == nil ? "Choose a route" : "Change route")
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
            }
        }
    }

    private var visiblePinnedBusRoute: String? {
        guard let pinnedBusRoute, isBusRouteDiscoverable(pinnedBusRoute) else { return nil }
        return pinnedBusRoute
    }

    private var busPickerRoutes: [String] {
        BusStopCatalog.allRoutes.filter { isBusRouteDiscoverable($0) }
    }

    private struct PinnedBusPickerNearbyEntry: Identifiable {
        let route: String
        let distanceMeters: Double
        var id: String { route }
    }

    /// Closest discoverable bus routes (deduplicated to one entry per route at
    /// its nearest stop), so the picker can surface "what's around me" before
    /// the full alphabetical list.
    private var nearbyBusRoutesForPicker: [PinnedBusPickerNearbyEntry] {
        guard let origin else { return [] }
        return NearestBusStopResolver(maxDistanceMeters: 1_500)
            .nearest(to: origin, limit: 30, catalog: BusStopCatalog.all)
            .filter { isBusRouteDiscoverable($0.route) }
            .prefix(8)
            .map { stop in
                PinnedBusPickerNearbyEntry(
                    route: stop.route,
                    distanceMeters: Distance.meters(
                        from: origin,
                        to: (stop.latitude, stop.longitude)
                    )
                )
            }
    }

    private func pinnedBusCard(route: String) -> some View {
        ChicagoCard(title: "Pinned bus",
                    eyebrow: isAutopinned ? "Autopinned bus" : "Pinned bus",
                    ornament: .icon(systemName: "bus.fill"),
                    accent: ChicagoPalette.Mode.bus) {
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
                    pinnedRouteControlRow(
                        title: "Route \(route)",
                        detail: pinnedBusDirection,
                        alerts: alerts(forBusRoute: route),
                        clearLabel: "Clear pinned Route \(route)",
                        clearAction: { setPinnedBus(nil) }
                    ) {
                        RouteBadge(bus: route, size: .md)
                    }
                    let visibleDirections: [BusDirectionStopChoice] = {
                        guard let pinned = pinnedBusDirection else { return directionChoices }
                        let filtered = directionChoices.filter { $0.directionLabel == pinned }
                        return filtered.isEmpty ? directionChoices : filtered
                    }()
                    ForEach(visibleDirections) { choice in
                        let selected = effectivePinnedBusStop(in: choice)
                        VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                            pinnedBusDirectionRow(route: route, stop: selected.stop, origin: origin)
                            if choice.stops.count > 1 {
                                busStopSelector(choice: choice, origin: origin)
                            }
                        }
                    }
                    if directionChoices.count > 1 {
                        directionPickerForBus(choices: directionChoices)
                    }
                }
                .task(id: busDirectionDefaultTaskKey(
                    route: route,
                    choices: directionChoices
                )) {
                    applyDefaultPinnedBusDirectionIfNeeded(
                        route: route,
                        choices: directionChoices
                    )
                }
                .task(id: accessTaskKey(prefix: "bus-\(route)", origin: origin)) {
                    model.walkingResolver.ensureFresh(
                        origin: origin,
                        stops: directionChoices.flatMap(\.stops).map(\.stop)
                    )
                    do {
                        try await Task.sleep(for: .seconds(2))
                        model.walkingResolver.ensureFresh(
                            origin: origin,
                            stops: directionChoices.map { effectivePinnedBusStop(in: $0).stop },
                            modes: [.cycling]
                        )
                    } catch {
                        // Cancelled because the origin or route changed.
                    }
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    private func busDirectionDefaultTaskKey(
        route: String,
        choices: [BusDirectionStopChoice]
    ) -> String {
        [
            route,
            pinnedBusDirection ?? "none",
            choices.map(\.directionLabel).joined(separator: "|")
        ].joined(separator: ":")
    }

    @MainActor
    private func applyDefaultPinnedBusDirectionIfNeeded(
        route: String,
        choices: [BusDirectionStopChoice]
    ) {
        guard pinSource == .manual,
              pinnedBusRoute == route,
              pinnedBusDirection == nil,
              choices.count > 1,
              let direction = defaultBusDirection(
                  route: route,
                  availableDirections: choices.map(\.directionLabel)
              )
        else { return }

        pinnedBusDirection = direction
        pinnedBusStopId = nil
        model.saveManualRoutePreferences {
            $0.pinnedBusDirection = direction
            $0.pinnedBusStopId = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
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
                            accent: ChicagoPalette.Mode.bus,
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

    private func busStopSelector(
        choice: BusDirectionStopChoice,
        origin: (lat: Double, lon: Double)
    ) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a stop")
            StationChipStrip {
                ForEach(choice.stops) { entry in
                    BusStopChip(
                        stop: entry.stop,
                        accessTime: accessTimeSummary(
                            origin: origin,
                            destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: entry.stop.id),
                            directDistanceMeters: entry.distance
                        ),
                        isSelected: entry.stop.id == effectivePinnedBusStop(in: choice).stop.id,
                        accent: ChicagoPalette.Mode.bus,
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
        let accessTime = accessTimeSummary(
            origin: origin,
            destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: stop.id),
            directDistanceMeters: distance
        )
        let predictions = model.snapshot.busPredictions
            .filter { $0.route == route && $0.stopId == stop.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let first = predictions.first
        let minutes = first.map { max(0, Int(($0.arrivalAt.timeIntervalSince(.now) / 60).rounded())) }
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(stop.directionLabel.isEmpty ? stop.name : stop.directionLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Mode.bus)
                Spacer()
                Text(AccessTimeFormatter.short(accessTime))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
                let biasCorrection = headlineBiasCorrection(for: predictions)
                let bunching = bunchingHint(for: predictions)
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
                if let biasCorrection {
                    Text(biasCorrection.displayText)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .accessibilityLabel(biasCorrection.accessibilityLabel)
                }
                if let bunching {
                    Text("+ another in \(bunching.minutes)m")
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                        .accessibilityLabel("Another bus in \(bunching.minutes) minutes")
                }
                HeadwayDotStrip(
                    arrivals: predictions.prefix(8).map(\.arrivalAt),
                    accent: ChicagoPalette.Mode.bus,
                    urgencies: departureUrgencies(
                        forBusStopId: stop.id,
                        predictions: predictions.prefix(8)
                    )
                )
            }
            busProgressStrip(toStop: stop, route: route)
        }
    }

    private func setPinnedBus(_ route: String?) {
        let defaultDirection = route.map {
            defaultBusDirection(route: $0, availableDirections: busDirectionLabels(for: $0))
        } ?? nil
        pinnedBusRoute = route
        pinnedBusDirection = defaultDirection
        pinnedBusStopId = nil
        model.saveManualRoutePreferences {
            $0.pinnedBusRoute = route
            $0.pinnedBusDirection = defaultDirection
            $0.pinnedBusStopId = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func busDirectionLabels(for route: String) -> [String] {
        guard let origin else { return [] }
        return busStopChoices(route: route, origin: origin).map(\.directionLabel)
    }

    private func defaultBusDirection(
        route: String,
        availableDirections: [String]
    ) -> String? {
        PinnedLineDefaultResolver().preferredBusDirection(
            route: route,
            availableDirections: availableDirections,
            preferences: routePreferences,
            profile: model.preferences.loadMobilityProfile(),
            context: model.location.context,
            location: model.location.lastKnown
        )
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
                if let route = visiblePinnedMetraRoute {
                    pickerPinnedConfirmationRow(
                        title: MetraStationCatalog.route(id: route)?.displayName ?? route,
                        clearLabel: "Clear pinned Metra \(route)",
                        clearAction: { setPinnedMetra(nil) }
                    ) {
                        RouteBadge(metra: route, size: .sm)
                    }
                }
                Menu {
                    if visiblePinnedMetraRoute != nil {
                        Button("Unpin", role: .destructive) { setPinnedMetra(nil) }
                        Divider()
                    }
                    ForEach(metraPickerRoutes, id: \.id) { line in
                        Button(line.displayName) { setPinnedMetra(line.id) }
                    }
                } label: {
                    HStack(spacing: ChicagoSpacing.xs) {
                        Image(systemName: "train.side.front.car")
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                        Text(visiblePinnedMetraRoute == nil ? "Choose a line" : "Change line")
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
            }
        }
    }

    private var visiblePinnedMetraRoute: String? {
        guard let pinnedMetraRoute, isMetraRouteDiscoverable(pinnedMetraRoute) else { return nil }
        return pinnedMetraRoute
    }

    private var metraPickerRoutes: [MetraLine] {
        MetraStationCatalog.routes.filter { isMetraRouteDiscoverable($0.id) }
    }

    private func pinnedMetraCard(route: String) -> some View {
        return ChicagoCard(title: "Pinned Metra",
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
                    pinnedRouteControlRow(
                        title: MetraStationCatalog.route(id: route)?.displayName ?? route,
                        detail: "Pinned Metra",
                        alerts: alerts(forMetraRoute: route),
                        clearLabel: "Clear pinned Metra \(route)",
                        clearAction: { setPinnedMetra(nil) }
                    ) {
                        RouteBadge(metra: route, size: .md)
                    }
                    pinnedMetraStationRow(route: route, station: selected.station, origin: origin)
                    directionPickerForMetra(route: route, station: selected.station)
                    metraStationSelector(choices: choices, origin: origin)
                }
                .task(id: accessTaskKey(prefix: "metra-\(route)", origin: origin)) {
                    model.walkingResolver.ensureFresh(
                        origin: origin,
                        metraStations: choices.map(\.station)
                    )
                    do {
                        try await Task.sleep(for: .seconds(2))
                        model.walkingResolver.ensureFresh(
                            origin: origin,
                            metraStation: selected.station,
                            modes: [.cycling]
                        )
                    } catch {
                        // Cancelled because the origin or route changed.
                    }
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

    private func metraStationSelector(
        choices: [MetraStationChoice],
        origin: (lat: Double, lon: Double)
    ) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a station")
            StationChipStrip {
                ForEach(choices) { entry in
                    MetraStationChip(
                        station: entry.station,
                        accessTime: accessTimeSummary(
                            origin: origin,
                            destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: entry.station.id),
                            directDistanceMeters: entry.distance
                        ),
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
        let groups = MetraStationCatalog.departureGroups(routeId: route, stationId: station.id)
        if groups.count > 1 {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Pick a direction")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ChicagoSpacing.xs) {
                        ForEach(groups) { group in
                            DirectionChip(
                                label: group.title,
                                isSelected: pinnedMetraDirectionId == group.directionId,
                                accent: pinnedMetraAccent,
                                action: { togglePinnedMetraDirection(group) }
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
        let accessTime = accessTimeSummary(
            origin: origin,
            destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: station.id),
            directDistanceMeters: distance
        )
        let predictions = metraPredictions(route: route, station: station)
        let group = MetraDepartureGrouper.groups(from: predictions, limitPerGroup: 3).first
        return VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(station.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.bahama)
                Spacer()
                Text(AccessTimeFormatter.short(accessTime))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
            } else if let group {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(1)
                    MetraDepartureListView(
                        predictions: group.departures,
                        maxCount: 3,
                        density: .regular,
                        accessibilityPrefix: "Metra \(group.title.lowercased()) departures"
                    )
                }
                HeadwayDotStrip(
                    arrivals: group.departures.prefix(8).map(\.arrivalAt),
                    accent: pinnedMetraAccent,
                    urgencies: departureUrgencies(
                        forMetraStationId: station.id,
                        predictions: group.departures.prefix(8)
                    )
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

    private func togglePinnedMetraDirection(_ group: MetraDepartureGroup) {
        let isSame = pinnedMetraDirectionId == group.directionId
        pinnedMetraDirectionId = isSame ? nil : group.directionId
        pinnedMetraDestination = nil
        model.saveManualRoutePreferences {
            $0.pinnedMetraDirectionId = isSame ? nil : group.directionId
            $0.pinnedMetraDestination = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bikes

    private var bikeCard: some View {
        ChicagoCard(title: "Closest e-bikes",
                    eyebrow: "Divvy",
                    ornament: .icon(systemName: "bicycle"),
                    accent: ChicagoPalette.Mode.divvy) {
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
                                .fill(ChicagoPalette.Gray.light.opacity(0.24))
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
                            .foregroundStyle(ChicagoPalette.Mode.divvy)
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

    /// Inline affordance shown in place of the nearby discovery
    /// section when the user has it disabled. Tapping flips the
    /// preference on, which makes the refresh path start fetching
    /// nearby routes and the dashboard reveals the full section on
    /// the next render. The button is small and unobtrusive — the
    /// nearby surface is opt-in to save background work.
    private var showNearbyButton: some View {
        Button {
            setNearbyDiscoveryEnabled(true)
        } label: {
            HStack(spacing: ChicagoSpacing.xs) {
                Image(systemName: "location.magnifyingglass")
                Text("Show nearby trains and buses")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
            }
            .padding(.horizontal, ChicagoSpacing.md)
            .padding(.vertical, ChicagoSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(ChicagoPalette.flagBlue)
        .accessibilityLabel("Show nearby trains and buses")
        .accessibilityHint("Reveals the discovery section and starts fetching nearby routes.")
    }

    private func setNearbyDiscoveryEnabled(_ enabled: Bool) {
        var prefs = model.preferences.loadRoutePreferences()
        guard prefs.nearbyDiscoveryEnabled != enabled else { return }
        prefs.nearbyDiscoveryEnabled = enabled
        model.preferences.saveRoutePreferences(prefs)
        model.pinRevision += 1
        Task { await model.refreshIfNeeded(force: true) }
    }

    private var nearYouSection: some View {
        // Each of `nearbyTrainCorridors` / `nearbyBusCorridors` /
        // `nearbyMetraRoutes` is a non-trivial scan of the bundled catalog
        // plus a walking-cache lookup per candidate. Bind each to a `let`
        // so the section's three sub-views and the divider visibility
        // check share one computation per body re-eval (down from up to
        // 3× per render).
        let trainCorridors = nearbyTrainCorridors
        let busCorridors = nearbyBusCorridors
        let metraRoutes = nearbyMetraRoutes
        return ChicagoCard(title: "Near you",
                    eyebrow: "Discover",
                    ornament: .icon(systemName: "location.fill")) {
            VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                if model.location.lastKnown == nil {
                    Text("Waiting for a location fix…")
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                } else {
                    nearbyLLines(corridors: trainCorridors)
                    if !trainCorridors.isEmpty
                        || !busCorridors.isEmpty
                        || !metraRoutes.isEmpty
                    {
                        Rectangle()
                            .fill(ChicagoPalette.Gray.light.opacity(0.28))
                            .frame(height: ChicagoSpacing.Stroke.hairline)
                    }
                    nearbyBuses(corridors: busCorridors)
                    nearbyMetra(routes: metraRoutes)
                    // Inline "hide" affordance so the user can collapse
                    // the section without opening Settings. Tucked at
                    // the bottom — discoverable when they're done
                    // exploring, invisible the rest of the time.
                    Button {
                        setNearbyDiscoveryEnabled(false)
                    } label: {
                        Label("Hide nearby", systemImage: "eye.slash")
                            .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(ChicagoPalette.Gray.medium)
                    .accessibilityHint("Collapses the discovery section and stops fetching nearby routes.")
                }
            }
        }
    }

    @ViewBuilder
    private func nearbyLLines(corridors: [TrainCorridorEntry]) -> some View {
        if !routePreferences.isModeVisible(.trains) {
            EmptyView()
        } else if !corridors.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Train corridors nearby")
                SmallMultiplesRow(corridors) { entry in
                    NearbyTrainCorridorTile(entry: entry, now: .now)
                }
            }
        } else {
            Text("No L corridors within 2 km")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    @ViewBuilder
    private func nearbyBuses(corridors: [BusCorridorEntry]) -> some View {
        if !routePreferences.isModeVisible(.buses) {
            EmptyView()
        } else if !corridors.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Bus corridors nearby")
                SmallMultiplesRow(corridors) { entry in
                    NearbyBusCorridorTile(entry: entry, now: .now)
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
    private func nearbyMetra(routes: [MetraEntry]) -> some View {
        if !routePreferences.isModeVisible(.metra) {
            EmptyView()
        } else if !routes.isEmpty {
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                sectionLabel("Metra nearby")
                SmallMultiplesRow(routes) { entry in
                    let group = MetraDepartureGrouper.groups(
                        from: metraPredictions(for: entry),
                        limitPerGroup: 3
                    ).first
                    DepartureTimesTile(
                        badge: RouteBadge(metra: entry.routeId, size: .md),
                        title: group?.title,
                        departures: group?.departures ?? [],
                        subtitle: entry.station.name
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

    private var closedStationIds: Set<Int> { closedStationIdsCache }

    private func recomputeClosedStationIdsIfNeeded() {
        let next = ClosedStationsAnalyzer.closedStationIds(
            from: model.snapshot.activeAlerts
        )
        if next != closedStationIdsCache {
            closedStationIdsCache = next
        }
    }

    private var nearbyTrainCorridors: [TrainCorridorEntry] {
        guard routePreferences.isModeVisible(.trains), let origin else { return [] }
        let candidates = corridorResolver.nearbyTrainCandidates(
            to: origin,
            radiusMeters: 2_000,
            limitPerCorridor: 5,
            catalog: LStationCatalog.all,
            excludingStationIds: closedStationIds,
            isLineVisible: isTrainLineDiscoverable
        )

        var bestByCorridor: [TransitCorridor: TrainCorridorEntry] = [:]
        for candidate in candidates {
            let walking = model.walkingResolver.cached(
                origin: origin,
                stationId: candidate.station.id
            )
            let distance = walking?.meters ?? candidate.distanceMeters
            let arrivals = arrivals(
                forLine: candidate.line,
                station: candidate.station,
                limit: 12
            )
            let entry = TrainCorridorEntry(
                corridor: candidate.corridor,
                line: candidate.line,
                station: candidate.station,
                distance: distance,
                directionGroups: trainDirectionGroups(from: arrivals),
                catchableArrivalAt: catchableArrival(from: arrivals, distanceMeters: distance)?.arrivalAt
            )
            if let current = bestByCorridor[candidate.corridor] {
                if isBetterTrainCorridorEntry(entry, than: current) {
                    bestByCorridor[candidate.corridor] = entry
                }
            } else {
                bestByCorridor[candidate.corridor] = entry
            }
        }

        return TransitCorridor.trainOrder.compactMap { bestByCorridor[$0] }
    }

    private var nearbyBusCorridors: [BusCorridorEntry] {
        guard routePreferences.isModeVisible(.buses), let origin else { return [] }
        let candidates = corridorResolver.nearbyBusCandidates(
            to: origin,
            radiusMeters: 1_500,
            limitPerCorridor: 8,
            catalog: BusStopCatalog.all,
            isRouteVisible: isBusRouteDiscoverable
        )

        var bestByCorridor: [TransitCorridor: BusCorridorEntry] = [:]
        for candidate in candidates {
            let predictions = predictions(for: candidate.stop, limit: 4)
            let entry = BusCorridorEntry(
                corridor: candidate.corridor,
                stop: candidate.stop,
                distance: candidate.distanceMeters,
                predictions: predictions,
                catchablePrediction: catchablePrediction(
                    from: predictions,
                    distanceMeters: candidate.distanceMeters
                )
            )
            if let current = bestByCorridor[candidate.corridor] {
                if isBetterBusCorridorEntry(entry, than: current) {
                    bestByCorridor[candidate.corridor] = entry
                }
            } else {
                bestByCorridor[candidate.corridor] = entry
            }
        }

        return TransitCorridor.busOrder.compactMap { bestByCorridor[$0] }
    }

    private var nearbyMetraRoutes: [MetraEntry] {
        guard routePreferences.isModeVisible(.metra), let origin else { return [] }
        return NearestMetraStationResolver(maxDistanceMeters: 3_000)
            .nearestPerRoute(
                to: origin,
                limit: 5,
                catalog: MetraStationCatalog.all
            )
            .filter { $0.routeId != pinnedMetraRoute }
            .filter { isMetraRouteDiscoverable($0.routeId) }
            .map { MetraEntry(routeId: $0.routeId, station: $0.station, distance: $0.distance) }
    }

    private func arrivals(
        forLine line: LineColor,
        station: LStation,
        limit: Int = 3
    ) -> [Arrival] {
        model.snapshot.trainArrivals
            .filter { $0.line == line && $0.stationId == station.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(limit)
            .map { $0 }
    }

    private func trainDirectionGroups(from arrivals: [Arrival]) -> [NearbyTrainDirectionGroup] {
        Dictionary(grouping: arrivals, by: \.directionCode)
            .map { _, grouped -> NearbyTrainDirectionGroup in
                let sortedArrivals = grouped.sorted { $0.arrivalAt < $1.arrivalAt }
                // Join the unique destinations in this direction (in
                // order-of-soonest-arrival) so the discovery surface
                // reads "→ Forest Park / UIC-Halsted" as one row.
                var seen: Set<String> = []
                let destinationLabel = sortedArrivals
                    .map(\.destinationName)
                    .filter { seen.insert($0).inserted }
                    .joined(separator: " / ")
                return NearbyTrainDirectionGroup(
                    destinationName: destinationLabel,
                    arrivals: sortedArrivals.prefix(2).map(\.arrivalAt)
                )
            }
            .sorted { lhs, rhs in
                guard let lhsFirst = lhs.arrivals.first else { return false }
                guard let rhsFirst = rhs.arrivals.first else { return true }
                return lhsFirst < rhsFirst
            }
            .prefix(2)
            .map { $0 }
    }

    private func catchableArrival(
        from arrivals: [Arrival],
        distanceMeters: Double,
        now: Date = .now
    ) -> Arrival? {
        let cutoff = now.addingTimeInterval(
            AccessTimeFormatter.approximateWalkingTravelTime(distanceMeters: distanceMeters)
                + NearbyTransitCatchability.boardingBuffer
        )
        return arrivals.first { $0.arrivalAt >= cutoff }
    }

    private func catchablePrediction(
        from predictions: [BusPrediction],
        distanceMeters: Double,
        now: Date = .now
    ) -> BusPrediction? {
        let cutoff = now.addingTimeInterval(
            AccessTimeFormatter.approximateWalkingTravelTime(distanceMeters: distanceMeters)
                + NearbyTransitCatchability.boardingBuffer
        )
        return predictions.first { $0.arrivalAt >= cutoff }
    }

    private func isBetterTrainCorridorEntry(
        _ lhs: TrainCorridorEntry,
        than rhs: TrainCorridorEntry
    ) -> Bool {
        if (lhs.catchableArrivalAt != nil) != (rhs.catchableArrivalAt != nil) {
            return lhs.catchableArrivalAt != nil
        }
        if let lhsArrival = lhs.catchableArrivalAt,
           let rhsArrival = rhs.catchableArrivalAt,
           lhsArrival != rhsArrival
        {
            return lhsArrival < rhsArrival
        }
        if let lhsNext = lhs.nextArrivalAt, let rhsNext = rhs.nextArrivalAt, lhsNext != rhsNext {
            return lhsNext < rhsNext
        }
        if (lhs.nextArrivalAt != nil) != (rhs.nextArrivalAt != nil) {
            return lhs.nextArrivalAt != nil
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        return lhs.line.rawValue < rhs.line.rawValue
    }

    private func isBetterBusCorridorEntry(
        _ lhs: BusCorridorEntry,
        than rhs: BusCorridorEntry
    ) -> Bool {
        if (lhs.catchablePrediction != nil) != (rhs.catchablePrediction != nil) {
            return lhs.catchablePrediction != nil
        }
        if let lhsArrival = lhs.catchablePrediction?.arrivalAt,
           let rhsArrival = rhs.catchablePrediction?.arrivalAt,
           lhsArrival != rhsArrival
        {
            return lhsArrival < rhsArrival
        }
        if let lhsNext = lhs.displayPrediction?.arrivalAt,
           let rhsNext = rhs.displayPrediction?.arrivalAt,
           lhsNext != rhsNext
        {
            return lhsNext < rhsNext
        }
        if (lhs.displayPrediction != nil) != (rhs.displayPrediction != nil) {
            return lhs.displayPrediction != nil
        }
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        return lhs.stop.route.localizedStandardCompare(rhs.stop.route) == .orderedAscending
    }

    private var trainVehiclePositions: [VehiclePosition] {
        model.vehiclePositions.isEmpty ? model.snapshot.vehiclePositions : model.vehiclePositions
    }

    private func ghostAssessments(
        for arrivals: [Arrival],
        now: Date = .now
    ) -> [String: GhostTrainAssessment] {
        GhostTrainDetector().assessments(
            for: arrivals,
            vehiclePositions: trainVehiclePositions,
            arrivalsFetchedAt: model.snapshot.trainsFetchedAt,
            now: now
        )
    }

    private func ghostComplications(
        for arrivals: ArraySlice<Arrival>,
        assessments: [String: GhostTrainAssessment]
    ) -> [HeadwayDotStrip.Complication?] {
        arrivals.map { assessments[$0.id]?.headwayComplication }
    }

    /// Look up a confident bias correction for the first arrival in
    /// `arrivals`, if `ArrivalBiasStore` has enough samples for that
    /// `(line, stopId, direction, hourClass, weekdayClass, season)` cell.
    /// Returns `nil` when the gates don't pass — callers render nothing.
    private func headlineBiasCorrection(
        for arrivals: [Arrival]
    ) -> ArrivalBiasCorrection? {
        let cells = model.arrivalBiasStore.cells
        return ArrivalBiasReader().headlineCorrection(
            arrivals: arrivals,
            cellLookup: { cells[$0] }
        )
    }

    /// Bus variant — same gates, keyed off `BusPrediction.route` /
    /// `stopId` / `directionName`.
    private func headlineBiasCorrection(
        for busPredictions: [BusPrediction]
    ) -> ArrivalBiasCorrection? {
        let cells = model.arrivalBiasStore.cells
        return ArrivalBiasReader().headlineCorrection(
            busPredictions: busPredictions,
            cellLookup: { cells[$0] }
        )
    }

    /// Real-time observation (not a learned prediction): is the
    /// headline arrival bunched with the next one? Pure function of
    /// the current API snapshot's spacing — flips the dashboard's
    /// "+ another in Nm" muted line on when the gap to the next
    /// arrival is anomalously short relative to subsequent gaps.
    private func bunchingHint(for arrivals: [Arrival]) -> HeadwayBunchingDetector.Hint? {
        HeadwayBunchingDetector().detect(arrivalTimes: arrivals.map(\.arrivalAt))
    }

    private func bunchingHint(for busPredictions: [BusPrediction]) -> HeadwayBunchingDetector.Hint? {
        HeadwayBunchingDetector().detect(arrivalTimes: busPredictions.map(\.arrivalAt))
    }

    private func bunchingHint(for metraPredictions: [MetraPrediction]) -> HeadwayBunchingDetector.Hint? {
        HeadwayBunchingDetector().detect(arrivalTimes: metraPredictions.map(\.arrivalAt))
    }

    /// Per-arrival departure urgency for the dot-strip thermometer.
    /// Returns `[]` (no overlays) when the user's current location or
    /// MapKit walking distance is unavailable — `HeadwayDotStrip`
    /// gracefully renders neutral dots in that case.
    private func departureUrgencies(
        forStationId stationId: Int,
        arrivals: ArraySlice<Arrival>
    ) -> [DepartureUrgency.Bucket?] {
        guard let lastKnown = model.location.lastKnown else { return [] }
        let origin = (lat: lastKnown.latitude, lon: lastKnown.longitude)
        guard let cached = model.walkingResolver.cached(origin: origin, stationId: stationId) else {
            return []
        }
        let now = Date()
        return arrivals.map { arrival in
            DepartureUrgency.from(
                arrivalAt: arrival.arrivalAt,
                walkSeconds: cached.expectedTravelTime,
                now: now
            )?.bucket
        }
    }

    private func departureUrgencies(
        forBusStopId stopId: Int,
        predictions: ArraySlice<BusPrediction>
    ) -> [DepartureUrgency.Bucket?] {
        guard let lastKnown = model.location.lastKnown else { return [] }
        let origin = (lat: lastKnown.latitude, lon: lastKnown.longitude)
        guard let cached = model.walkingResolver.cached(
            origin: origin,
            destinationKey: WalkingDistanceStore.busStopDestinationKey(stopId: stopId),
            mode: .walking
        ) else {
            return []
        }
        let now = Date()
        return predictions.map { prediction in
            DepartureUrgency.from(
                arrivalAt: prediction.arrivalAt,
                walkSeconds: cached.expectedTravelTime,
                now: now
            )?.bucket
        }
    }

    private func departureUrgencies(
        forMetraStationId stationId: String,
        predictions: ArraySlice<MetraPrediction>
    ) -> [DepartureUrgency.Bucket?] {
        guard let lastKnown = model.location.lastKnown else { return [] }
        let origin = (lat: lastKnown.latitude, lon: lastKnown.longitude)
        guard let cached = model.walkingResolver.cached(
            origin: origin,
            destinationKey: WalkingDistanceStore.metraStationDestinationKey(stationId: stationId),
            mode: .walking
        ) else {
            return []
        }
        let now = Date()
        return predictions.map { prediction in
            DepartureUrgency.from(
                arrivalAt: prediction.arrivalAt,
                walkSeconds: cached.expectedTravelTime,
                now: now
            )?.bucket
        }
    }

    private func predictions(for stop: BusStop, limit: Int = 3) -> [BusPrediction] {
        model.snapshot.busPredictions
            .filter { $0.stopId == stop.id && $0.route == stop.route }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(limit)
            .map { $0 }
    }

    private func metraPredictions(for entry: MetraEntry) -> [MetraPrediction] {
        model.snapshot.metraPredictions
            .filter { $0.stationId == entry.station.id && $0.routeId == entry.routeId }
            .sorted { $0.arrivalAt < $1.arrivalAt }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Top rail

    private func topPinnedRoutesRail(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: ChicagoSpacing.xs) {
            HStack(spacing: ChicagoSpacing.xs) {
                ForEach(DashboardRailMode.allCases) { mode in
                    Button {
                        scrollToRailMode(mode, using: scrollProxy)
                    } label: {
                        railSlot(for: mode)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isRailModeReachable(mode))
                    .accessibilityLabel(routeRailAccessibilityLabel(for: mode))
                }
            }

            if let plannedTripPin {
                plannedTripRailRow(plannedTripPin, scrollProxy: scrollProxy)
            }
        }
        .padding(.horizontal, ChicagoSpacing.md)
        .padding(.vertical, ChicagoSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChicagoPalette.Surface.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ChicagoPalette.Gray.light.opacity(0.28))
                .frame(height: ChicagoSpacing.Stroke.hairline)
        }
    }

    private func plannedTripRailRow(
        _ pin: PlannedTripPin,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let tokens = plannedTripRouteTokens(for: pin)
        return Button {
            scrollToPlannedTrip(using: scrollProxy)
        } label: {
            HStack(spacing: ChicagoSpacing.xs) {
                Image(systemName: "map.fill")
                    .font(ChicagoTypography.body(.bold, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.flagBlue)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(plannedTripRailTitle(for: pin))
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !tokens.isEmpty {
                    plannedTripRouteTokenStack(tokens, limit: 3)
                }
            }
            .padding(.horizontal, ChicagoSpacing.sm)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChicagoPalette.Surface.elevated,
                        in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .strokeBorder(ChicagoPalette.flagBlue.opacity(0.22),
                                  lineWidth: ChicagoSpacing.Stroke.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(plannedTripRailAccessibilityLabel(for: pin))
    }

    private func scrollToRailMode(
        _ mode: DashboardRailMode,
        using scrollProxy: ScrollViewProxy
    ) {
        guard isRailModeReachable(mode) else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            scrollProxy.scrollTo(railDestination(for: mode), anchor: .top)
        }
    }

    private func scrollToPlannedTrip(using scrollProxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.24)) {
            scrollProxy.scrollTo(DashboardRailDestination.plannedTrip, anchor: .top)
        }
    }

    private func railDestination(for mode: DashboardRailMode) -> DashboardRailDestination {
        switch mode {
        case .train:
            return pinnedLine == nil ? .trainPicker : .pinnedTrain
        case .bus:
            return pinnedBusRoute == nil ? .busPicker : .pinnedBus
        case .metra:
            return pinnedMetraRoute == nil ? .metraPicker : .pinnedMetra
        case .intercampus:
            return .intercampus
        }
    }

    private func isRailModeReachable(_ mode: DashboardRailMode) -> Bool {
        switch mode {
        case .train:
            return shouldShowTrainSurfaces || pinnedLine != nil
        case .bus:
            return shouldShowBusSurfaces || pinnedBusRoute != nil
        case .metra:
            return shouldShowMetraSurfaces || pinnedMetraRoute != nil
        case .intercampus:
            return shouldShowIntercampusSurface
        }
    }

    private func isRailModePinned(_ mode: DashboardRailMode) -> Bool {
        switch mode {
        case .train:
            return pinnedLine != nil
        case .bus:
            return pinnedBusRoute != nil
        case .metra:
            return pinnedMetraRoute != nil
        case .intercampus:
            return pinnedIntercampusDirection != nil || pinnedIntercampusStopId != nil || plannedTripHasIntercampus
        }
    }

    private func routeRailAccessibilityLabel(for mode: DashboardRailMode) -> String {
        switch mode {
        case .train:
            if let pinnedLine {
                return "\(pinnedLine.displayName) train pinned. Jump to pinned train."
            }
            return "Train routes. Jump to train picker."
        case .bus:
            if let pinnedBusRoute {
                return "Route \(pinnedBusRoute) bus pinned. Jump to pinned bus."
            }
            return "Bus routes. Jump to bus picker."
        case .metra:
            if let pinnedMetraRoute {
                let name = MetraStationCatalog.route(id: pinnedMetraRoute)?.displayName ?? pinnedMetraRoute
                return "\(name) pinned. Jump to pinned Metra."
            }
            return "Metra lines. Jump to Metra picker."
        case .intercampus:
            if let direction = activeIntercampusRailDirection {
                return "\(direction.label) Intercampus pinned. Jump to Intercampus."
            }
            if pinnedIntercampusStopId != nil {
                return "Intercampus stop pinned. Jump to Intercampus."
            }
            return "Intercampus shuttle. Jump to Intercampus."
        }
    }

    private func railSlot(for mode: DashboardRailMode) -> some View {
        let isPinned = isRailModePinned(mode)
        let isReachable = isRailModeReachable(mode)
        return ZStack {
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .fill(isPinned ? ChicagoPalette.Surface.card : ChicagoPalette.Surface.elevated)
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(
                    railBorderColor(for: mode).opacity(isPinned ? 0.55 : 0.25),
                    lineWidth: ChicagoSpacing.Stroke.hairline
                )
            railSlotContent(for: mode)
                .frame(minWidth: 44, minHeight: 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .opacity(isReachable ? 1 : 0.38)
        .contentShape(RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    @ViewBuilder
    private func railSlotContent(for mode: DashboardRailMode) -> some View {
        switch mode {
        case .train:
            if let line = pinnedLine {
                RouteBadge(line: line, size: .sm)
            } else {
                railModeIcon(mode)
            }
        case .bus:
            if let route = pinnedBusRoute {
                RouteBadge(bus: route, size: .sm)
            } else {
                railModeIcon(mode)
            }
        case .metra:
            if let route = pinnedMetraRoute {
                RouteBadge(metra: route, size: .sm)
            } else {
                railModeIcon(mode)
            }
        case .intercampus:
            if activeIntercampusRailDirection != nil || pinnedIntercampusStopId != nil || plannedTripHasIntercampus {
                IntercampusRailBadge(direction: activeIntercampusRailDirection)
            } else {
                railModeIcon(mode)
            }
        }
    }

    private func railModeIcon(_ mode: DashboardRailMode) -> some View {
        Image(systemName: mode.systemImage)
            .font(ChicagoTypography.body(.bold, relativeTo: .caption))
            .foregroundStyle(ChicagoPalette.Gray.medium)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private func railBorderColor(for mode: DashboardRailMode) -> Color {
        switch mode {
        case .train:
            return pinnedLine?.swiftUIColor ?? ChicagoPalette.Gray.light
        case .bus:
            return pinnedBusRoute == nil ? ChicagoPalette.Gray.light : ChicagoPalette.Mode.bus
        case .metra:
            return pinnedMetraRoute
                .flatMap { MetraStationCatalog.route(id: $0)?.swiftUIColor } ?? ChicagoPalette.Gray.light
        case .intercampus:
            return ChicagoPalette.Mode.intercampus
        }
    }

    private func plannedTripRailTitle(for pin: PlannedTripPin) -> String {
        let label = pin.destination.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Planned trip" : label
    }

    private func plannedTripRailAccessibilityLabel(for pin: PlannedTripPin) -> String {
        let routeSummary = pin.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let via = routeSummary.isEmpty ? "" : " via \(routeSummary)"
        return "Pinned trip to \(plannedTripRailTitle(for: pin))\(via). Jump to trip card."
    }

    private func plannedTripRouteTokens(for pin: PlannedTripPin) -> [DashboardTripRouteToken] {
        let trainTokens = pin.trainLegs.map {
            DashboardTripRouteToken(
                kind: .train($0.line),
                summaryLabel: $0.line.displayName
            )
        }
        let busTokens = pin.busLegs.map {
            DashboardTripRouteToken(
                kind: .bus($0.route),
                summaryLabel: "Route \($0.route)"
            )
        }
        let metraTokens = pin.metraLegs.map {
            DashboardTripRouteToken(
                kind: .metra($0.routeId),
                summaryLabel: "Metra \(MetraStationCatalog.route(id: $0.routeId)?.shortName ?? $0.routeId)"
            )
        }
        let intercampusTokens = pin.intercampusLegs.map {
            DashboardTripRouteToken(
                kind: .intercampus($0.direction),
                summaryLabel: "Intercampus"
            )
        }
        let tokens = trainTokens + busTokens + metraTokens + intercampusTokens
        let summaryPieces = pin.summary
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        var ordered: [DashboardTripRouteToken] = []
        for piece in summaryPieces {
            guard let token = tokens.first(where: {
                $0.summaryLabel == piece && !seen.contains($0.id)
            }) else { continue }
            ordered.append(token)
            seen.insert(token.id)
        }
        for token in tokens where !seen.contains(token.id) {
            ordered.append(token)
            seen.insert(token.id)
        }
        return ordered
    }

    private func plannedTripRouteTokenStack(
        _ tokens: [DashboardTripRouteToken],
        limit: Int
    ) -> some View {
        let visibleTokens = Array(tokens.prefix(limit))
        let overflowCount = max(0, tokens.count - visibleTokens.count)
        return HStack(spacing: ChicagoSpacing.xs) {
            ForEach(visibleTokens) { token in
                plannedTripRouteTokenView(token)
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(ChicagoTypography.body(.bold, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .padding(.horizontal, ChicagoSpacing.xs)
                    .padding(.vertical, 2)
                    .background(ChicagoPalette.Surface.card,
                                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm))
            }
        }
    }

    @ViewBuilder
    private func plannedTripRouteTokenView(_ token: DashboardTripRouteToken) -> some View {
        switch token.kind {
        case .train(let line):
            RouteBadge(line: line, size: .sm)
        case .bus(let route):
            RouteBadge(bus: route, size: .sm)
        case .metra(let routeId):
            RouteBadge(metra: routeId, size: .sm)
        case .intercampus(let direction):
            IntercampusRailBadge(direction: direction)
        }
    }

    // MARK: - Alerts

    private func alerts(forLine line: LineColor) -> [ServiceAlert] {
        orderedAlerts(
            model.snapshot.activeAlerts.filtered(
                forLines: Set([line]),
                busRoutes: [],
                metraRoutes: []
            )
        )
    }

    private func alerts(forBusRoute route: String) -> [ServiceAlert] {
        orderedAlerts(
            model.snapshot.activeAlerts.filtered(
                forLines: [],
                busRoutes: Set([route]),
                metraRoutes: []
            )
        )
    }

    private func alerts(forMetraRoute route: String) -> [ServiceAlert] {
        orderedAlerts(
            model.snapshot.activeAlerts.filtered(
                forLines: [],
                busRoutes: [],
                metraRoutes: Set([route])
            )
        )
    }

    private func orderedAlerts(_ alerts: [ServiceAlert]) -> [ServiceAlert] {
        alerts.sorted {
            let left = alertSeverityRank($0.severity)
            let right = alertSeverityRank($1.severity)
            if left != right { return left > right }
            return $0.beginsAt > $1.beginsAt
        }
    }

    private func alertSummaryText(_ alerts: [ServiceAlert]) -> String {
        guard let first = alerts.first else { return "" }
        let label = alerts.count == 1 ? "Service alert" : "\(alerts.count) service alerts"
        return "\(label): \(first.headline)"
    }

    private func alertDetailURL(for alerts: [ServiceAlert]) -> URL {
        alerts.first?.detailURL ?? ServiceAlert.detailsURL
    }

    private func alertColor(for alerts: [ServiceAlert]) -> Color {
        let severity = alerts
            .map(\.severity)
            .max { alertSeverityRank($0) < alertSeverityRank($1) } ?? .low
        switch severity {
        case .high:   return ChicagoPalette.starRed
        case .medium: return ChicagoPalette.gold
        case .low:    return ChicagoPalette.bahama
        }
    }

    private func alertSeverityRank(_ severity: AlertSeverity) -> Int {
        switch severity {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    private func pinAlertInlineSummary(_ alerts: [ServiceAlert]) -> some View {
        let alerts = orderedAlerts(alerts)
        return Link(destination: alertDetailURL(for: alerts)) {
            HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .accessibilityHidden(true)
                Text(alertSummaryText(alerts))
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(alertColor(for: alerts))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(alertSummaryText(alerts))
    }

    // MARK: - Tiny helpers

    private func pickerPinnedConfirmationRow<Badge: View>(
        title: String,
        clearLabel: String,
        clearAction: @escaping () -> Void,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
            Text("Pinned")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
            badge()
            Text(title)
                .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: ChicagoSpacing.xs)
            Text("Shown below")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
                .lineLimit(1)
            Button(action: clearAction) {
                Image(systemName: "pin.slash")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clearLabel)
        }
        .padding(.horizontal, ChicagoSpacing.sm)
        .padding(.vertical, ChicagoSpacing.xs)
        .background(
            ChicagoPalette.Surface.elevated,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(
                    ChicagoPalette.Gray.light.opacity(0.26),
                    lineWidth: ChicagoSpacing.Stroke.hairline
                )
        )
    }

    private func pinnedRouteControlRow<Badge: View>(
        title: String,
        detail: String? = nil,
        alerts: [ServiceAlert] = [],
        clearLabel: String,
        clearAction: @escaping () -> Void,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        HStack(alignment: .center, spacing: ChicagoSpacing.sm) {
            badge()
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                if !alerts.isEmpty {
                    pinAlertInlineSummary(alerts)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: ChicagoSpacing.sm)
            Button(action: clearAction) {
                Image(systemName: "pin.slash")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clearLabel)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(ChicagoTypography.body(.medium, relativeTo: .caption))
            .foregroundStyle(ChicagoPalette.Gray.medium)
    }

    // MARK: - Portfolio (Phase 5)

    /// Renders one card per active portfolio. Each card shows every
    /// option ranked by score with the hysteresis-approved
    /// recommendation highlighted. Empty when the user has no
    /// portfolios.
    @ViewBuilder
    private var portfolioSection: some View {
        let portfolios = routePreferences.portfolios
        if !portfolios.isEmpty {
            ForEach(portfolios) { portfolio in
                portfolioCard(portfolio)
            }
        }
    }

    private func portfolioCard(_ portfolio: RoutePortfolio) -> some View {
        let evaluation = model.portfolioEvaluations[portfolio.id]
        let recommendation = model.portfolioRecommendations[portfolio.id]
        let sortedOptions = sortedPortfolioOptions(portfolio: portfolio, evaluation: evaluation)

        return ChicagoCard(
            title: portfolio.title,
            eyebrow: "Portfolio · \(portfolio.direction.label)",
            ornament: .icon(systemName: "list.bullet.rectangle.fill"),
            accent: ChicagoPalette.flagBlue
        ) {
            if sortedOptions.isEmpty {
                Text("No options yet.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else if evaluation == nil {
                Text(model.isRefreshing ? "Evaluating…" : "Waiting for the next refresh.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                    ForEach(sortedOptions) { option in
                        portfolioOptionRow(
                            option: option,
                            evaluation: evaluation?.evaluation(for: option.id),
                            isRecommended: recommendation?.optionID == option.id,
                            recommendation: recommendation
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: recommendation?.optionID)
            }
        }
    }

    /// Stable per-option ordering: by aggregate score (ascending) when
    /// an evaluation exists, otherwise by the portfolio's stored order.
    /// Same-score ties fall back to insertion order so the list
    /// doesn't shuffle on equally-good options.
    private func sortedPortfolioOptions(
        portfolio: RoutePortfolio,
        evaluation: PortfolioEvaluation?
    ) -> [RouteOption] {
        guard let scores = evaluation?.scores else { return portfolio.options }
        return portfolio.options
            .enumerated()
            .sorted { lhs, rhs in
                let a = scores[lhs.element.id] ?? .infinity
                let b = scores[rhs.element.id] ?? .infinity
                if a == b { return lhs.offset < rhs.offset }
                return a < b
            }
            .map(\.element)
    }

    @ViewBuilder
    private func portfolioOptionRow(
        option: RouteOption,
        evaluation: RouteEvaluation?,
        isRecommended: Bool,
        recommendation: PortfolioRecommendation?
    ) -> some View {
        HStack(alignment: .top, spacing: ChicagoSpacing.sm) {
            portfolioOptionBadge(option)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(ChicagoTypography.body(
                        isRecommended ? .medium : .regular,
                        relativeTo: isRecommended ? .subheadline : .footnote
                    ))
                    .foregroundStyle(isRecommended
                        ? ChicagoPalette.Gray.darkest
                        : ChicagoPalette.Gray.dark)
                    .lineLimit(1)
                if let evaluation, !evaluation.available {
                    Text(portfolioUnavailabilityText(for: evaluation.unavailableReason))
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                } else if isRecommended, let missCost = recommendation?.missCost {
                    portfolioMissCostLine(
                        missCost,
                        lowConfidence: recommendation?.lowConfidence ?? false
                    )
                }
            }
            Spacer(minLength: ChicagoSpacing.sm)
            if let evaluation {
                portfolioOptionEta(evaluation: evaluation, prominent: isRecommended)
            }
        }
        .padding(.vertical, isRecommended ? ChicagoSpacing.xs : 0)
        .padding(.horizontal, isRecommended ? ChicagoSpacing.sm : 0)
        .background(
            isRecommended ? ChicagoPalette.Surface.elevated : .clear,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
    }

    @ViewBuilder
    private func portfolioOptionBadge(_ option: RouteOption) -> some View {
        if let resolution = option.firstTransitLeg?.transit?.resolution {
            switch resolution {
            case .line(let line):
                RouteBadge(line: line, size: .sm)
            case .bus(let route):
                RouteBadge(bus: route, size: .sm)
            case .metra(let route):
                RouteBadge(metra: route, size: .sm)
            case .unknown:
                Image(systemName: "questionmark.diamond")
                    .font(.caption)
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        } else {
            Image(systemName: "figure.walk")
                .font(.caption)
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    @ViewBuilder
    private func portfolioOptionEta(evaluation: RouteEvaluation, prominent: Bool) -> some View {
        if evaluation.available {
            let minutes = max(0, Int((evaluation.etaMedian.timeIntervalSince(.now) / 60).rounded()))
            if prominent {
                BigNumber(
                    minutes,
                    unit: "min",
                    size: .sm,
                    tone: .primary,
                    accessibilityLabel: "\(minutes) minutes"
                )
            } else {
                Text("\(minutes) min")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
        } else {
            Image(systemName: "minus.circle")
                .font(.caption)
                .foregroundStyle(ChicagoPalette.Gray.light)
        }
    }

    @ViewBuilder
    private func portfolioMissCostLine(
        _ missCost: MissCostResult,
        lowConfidence: Bool
    ) -> some View {
        let opacity: Double = lowConfidence ? 0.55 : 1.0
        if missCost.collapses {
            Text("Last vehicle — no fallback")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.starRed.opacity(opacity))
                .lineLimit(1)
        } else if missCost.delta.isFinite, missCost.delta > 0 {
            let mins = max(1, Int((missCost.delta / 60).rounded()))
            Text("Miss cost: +\(mins) min")
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium.opacity(opacity))
                .lineLimit(1)
        } else {
            EmptyView()
        }
    }

    private func portfolioUnavailabilityText(for reason: UnavailableReason?) -> String {
        switch reason {
        case .noArrivalsInHorizon:
            return "No arrivals in the next 45 min."
        case .lastVehicleAlreadyPassed:
            return "Last vehicle already left."
        case .staleFeed:
            return "Feed delayed."
        case .userTooFar:
            return "Too far from boarding stop."
        case .closedStation(let ids):
            return "Closed station: \(ids.map(String.init).joined(separator: ", "))."
        case .none:
            return "Unavailable."
        }
    }
}

private extension View {
    func dismissKeyboardOnTapAway() -> some View {
        background(KeyboardDismissTapBridge())
    }
}

private struct KeyboardDismissTapBridge: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> KeyboardDismissTapView {
        let view = KeyboardDismissTapView()
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardDismissTapView, context: Context) {
        let coordinator = context.coordinator
        uiView.onWindowChange = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        coordinator.attach(to: uiView.window)
    }

    static func dismantleUIView(_ uiView: KeyboardDismissTapView, coordinator: Coordinator) {
        uiView.onWindowChange = nil
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        func attach(to newWindow: UIWindow?) {
            if let window, let newWindow, window === newWindow { return }
            if window == nil, newWindow == nil { return }

            detach()

            guard let newWindow else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            newWindow.addGestureRecognizer(recognizer)
            window = newWindow
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer, let view = recognizer.view {
                view.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            window = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = touch.view else { return true }
            return !view.isInsideEditableTextInput
        }
    }
}

private final class KeyboardDismissTapView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

private extension UIView {
    var isInsideEditableTextInput: Bool {
        var view: UIView? = self
        while let currentView = view {
            if currentView is UITextField || currentView is UITextView || currentView is UISearchTextField {
                return true
            }
            view = currentView.superview
        }
        return false
    }
}

// MARK: - Manual destination anchor entry

private enum DestinationAnchorKind: String, Identifiable {
    case home
    case work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .work: "Work"
        }
    }

    var destinationKind: PlannedTripPin.DestinationKind {
        switch self {
        case .home: .home
        case .work: .work
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .work: "briefcase.fill"
        }
    }

    var tint: Color {
        switch self {
        case .home: ChicagoPalette.flagBlue
        case .work: ChicagoPalette.starRed
        }
    }

    func anchor(in anchors: CommuteAnchors) -> CommuteAnchors.Anchor? {
        switch self {
        case .home: anchors.home
        case .work: anchors.work
        }
    }
}

private struct AnchorAddressEntry: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let kind: DestinationAnchorKind

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
                    Text(kind.title)
                }

                statusSection

                if let coordinate {
                    Section("Preview") {
                        Map(position: $camera, interactionModes: [.pan, .zoom]) {
                            Marker(kind.title, coordinate: coordinate).tint(kind.tint)
                        }
                        .frame(height: 220)
                    }
                }
            }
            .navigationTitle("\(kind.title) address")
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
                if let existing = kind.anchor(in: model.preferences.loadCommuteAnchors()) {
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
        switch kind {
        case .home:
            model.setHomeAnchor(latitude: coordinate.latitude, longitude: coordinate.longitude)
        case .work:
            model.setWorkAnchor(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
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

private enum DashboardRailMode: String, CaseIterable, Identifiable {
    case train
    case bus
    case metra
    case intercampus

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .train: "tram.fill"
        case .bus: "bus.fill"
        case .metra: "train.side.front.car"
        case .intercampus: "graduationcap.fill"
        }
    }
}

private enum DashboardRailDestination: Hashable {
    case intercampus
    case trainPicker
    case pinnedTrain
    case busPicker
    case pinnedBus
    case metraPicker
    case pinnedMetra
    case plannedTrip
}

private struct DashboardTripRouteToken: Identifiable, Hashable {
    enum Kind: Hashable {
        case train(LineColor)
        case bus(String)
        case metra(String)
        case intercampus(IntercampusDirection)
    }

    let kind: Kind
    let summaryLabel: String

    var id: String {
        switch kind {
        case .train(let line):
            return "train-\(line.rawValue)"
        case .bus(let route):
            return "bus-\(route)"
        case .metra(let routeId):
            return "metra-\(routeId)"
        case .intercampus(let direction):
            return "intercampus-\(direction.rawValue)"
        }
    }
}

private struct IntercampusRailBadge: View {
    let direction: IntercampusDirection?

    var body: some View {
        Text(label)
            .font(ChicagoTypography.body(.bold, size: 11, relativeTo: .caption))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ChicagoPalette.Mode.intercampus,
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var label: String {
        switch direction {
        case .some(.northbound): "NB"
        case .some(.southbound): "SB"
        case .none: "IC"
        }
    }

    private var accessibilityLabel: String {
        switch direction {
        case .some(.northbound): "Northbound Intercampus"
        case .some(.southbound): "Southbound Intercampus"
        case .none: "Intercampus"
        }
    }
}

// MARK: - Row entry types

private struct TrainCorridorEntry: Identifiable {
    let corridor: TransitCorridor
    let line: LineColor
    let station: LStation
    let distance: Double
    let directionGroups: [NearbyTrainDirectionGroup]
    let catchableArrivalAt: Date?

    var id: String { "\(corridor.rawValue)-\(line.rawValue)-\(station.id)" }

    var nextArrivalAt: Date? {
        directionGroups.compactMap(\.arrivals.first).min()
    }
}

private struct NearbyTrainDirectionGroup: Identifiable, Hashable {
    /// Destinations sharing the same `Arrival.directionCode`, joined
    /// with " / " for display. E.g. "Forest Park / UIC-Halsted".
    let destinationName: String
    let arrivals: [Date]

    var id: String { destinationName }
}

private struct BusCorridorEntry: Identifiable {
    let corridor: TransitCorridor
    let stop: BusStop
    let distance: Double
    let predictions: [BusPrediction]
    let catchablePrediction: BusPrediction?

    var id: String { "\(corridor.rawValue)-\(stop.id)-\(stop.route)" }

    var displayPrediction: BusPrediction? {
        catchablePrediction ?? predictions.first
    }

    var displayDirection: String {
        if let prediction = displayPrediction, !prediction.directionName.isEmpty {
            return prediction.directionName
        }
        return stop.directionLabel
    }
}

private struct MetraEntry: Identifiable {
    let routeId: String
    let station: MetraStation
    let distance: Double
    var id: String { "\(routeId)-\(station.id)" }
}

private struct NearbyTrainCorridorTile: View {
    let entry: TrainCorridorEntry
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                corridorLabel(entry.corridor)
                RouteBadge(line: entry.line, size: .sm)
            }
            Text(entry.station.name)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(walkLabel)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
                .lineLimit(1)

            if entry.directionGroups.isEmpty {
                Text("No trains")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entry.directionGroups) { group in
                        HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
                            Text(shortDestination(group.destinationName))
                                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                                .foregroundStyle(ChicagoPalette.Gray.darkest)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: ChicagoSpacing.xs)
                            Text(minutesList(group.arrivals))
                                .font(ChicagoTypography.body(.bold, relativeTo: .caption))
                                .monospacedDigit()
                                .foregroundStyle(entry.line.swiftUIColor)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(width: 150, height: 132, alignment: .topLeading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(ChicagoPalette.Gray.light.opacity(0.26),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var walkLabel: String {
        AccessTimeFormatter.short(AccessTimeSummary(
            walkingTravelTime: AccessTimeFormatter.approximateWalkingTravelTime(distanceMeters: entry.distance),
            isApproximateWalkingTime: true,
            cyclingTravelTime: nil
        ))
    }

    private var accessibilityLabel: String {
        let directionText = entry.directionGroups
            .map { "\($0.destinationName), \(minutesList($0.arrivals)) minutes" }
            .joined(separator: ", ")
        return "\(entry.corridor.displayName), \(entry.line.displayName), \(entry.station.name), \(walkLabel), \(directionText)"
    }

    private func minutesList(_ dates: [Date]) -> String {
        let minutes = dates.map { max(0, Int(($0.timeIntervalSince(now) / 60).rounded())) }
        guard !minutes.isEmpty else { return "No train" }
        return minutes.map(String.init).joined(separator: ", ")
    }

    private func shortDestination(_ destination: String) -> String {
        if destination.count <= 14 { return destination }
        if let slash = destination.firstIndex(of: "/") {
            return String(destination[..<slash])
        }
        return destination
    }

    private func corridorLabel(_ corridor: TransitCorridor) -> some View {
        Text(corridor.shortLabel)
            .font(ChicagoTypography.body(.bold, relativeTo: .caption2))
            .foregroundStyle(ChicagoPalette.Gray.medium)
            .padding(.horizontal, ChicagoSpacing.xs)
            .padding(.vertical, 2)
            .background(
                ChicagoPalette.Surface.elevated,
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
            )
    }
}

private struct NearbyBusCorridorTile: View {
    let entry: BusCorridorEntry
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                corridorLabel(entry.corridor)
                RouteBadge(bus: entry.stop.route, size: .sm)
            }
            Text(entry.displayDirection)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(entry.stop.name)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
            if let prediction = entry.displayPrediction {
                let minutes = max(0, Int((prediction.arrivalAt.timeIntervalSince(now) / 60).rounded()))
                BigNumber(
                    minutes,
                    unit: "min",
                    size: .md,
                    tone: prediction.isDelayed ? .alert : .primary,
                    accessibilityLabel: "\(minutes) minutes to route \(entry.stop.route)"
                )
            } else {
                Text("No buses")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
            Text(walkLabel)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
                .lineLimit(1)
        }
        .padding(ChicagoSpacing.sm)
        .frame(width: 138, height: 132, alignment: .topLeading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(ChicagoPalette.Gray.light.opacity(0.26),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var walkLabel: String {
        AccessTimeFormatter.short(AccessTimeSummary(
            walkingTravelTime: AccessTimeFormatter.approximateWalkingTravelTime(distanceMeters: entry.distance),
            isApproximateWalkingTime: true,
            cyclingTravelTime: nil
        ))
    }

    private var accessibilityLabel: String {
        let minutes = entry.displayPrediction.map {
            "\(max(0, Int(($0.arrivalAt.timeIntervalSince(now) / 60).rounded()))) minutes"
        } ?? "no buses"
        return "\(entry.corridor.displayName), bus route \(entry.stop.route), \(entry.displayDirection), \(entry.stop.name), \(minutes), \(walkLabel)"
    }

    private func corridorLabel(_ corridor: TransitCorridor) -> some View {
        Text(corridor.shortLabel)
            .font(ChicagoTypography.body(.bold, relativeTo: .caption2))
            .foregroundStyle(ChicagoPalette.Gray.medium)
            .padding(.horizontal, ChicagoSpacing.xs)
            .padding(.vertical, 2)
            .background(
                ChicagoPalette.Surface.elevated,
                in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
            )
    }
}

private extension TransitCorridor {
    var shortLabel: String {
        switch self {
        case .northSouth: "N/S"
        case .eastWest: "E/W"
        case .diagonal: "Diag"
        case .loop: "Loop"
        }
    }

    var displayName: String {
        switch self {
        case .northSouth: "north south corridor"
        case .eastWest: "east west corridor"
        case .diagonal: "diagonal corridor"
        case .loop: "Loop corridor"
        }
    }
}

private struct IntercampusDirectionStopChoice: Identifiable {
    let direction: IntercampusDirection
    let stops: [IntercampusStopChoice]

    var id: IntercampusDirection { direction }
}

private struct IntercampusStopChoice: Identifiable, Hashable {
    let direction: IntercampusDirection
    let stop: IntercampusStop
    let directDistanceMeters: Double
    let walkingDistanceMeters: Double?
    let accessDistanceMeters: Double
    let displayTravelTime: TimeInterval
    let isApproximateTravelTime: Bool

    var id: String { "\(direction.rawValue)-\(stop.id)" }

    var walkTimeText: String {
        let minutes = max(1, Int((displayTravelTime / 60).rounded()))
        return "\(isApproximateTravelTime ? "≈" : "")\(minutes) min walk"
    }

    var accessibilityWalkTimeText: String {
        let minutes = max(1, Int((displayTravelTime / 60).rounded()))
        return "\(isApproximateTravelTime ? "about " : "")\(minutes) minute walk"
    }
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
    let boardingAccess: HomeTripBoardingAccess?
    let trainChoices: [HomeTripTrainChoice]
    let busChoices: [HomeTripBusChoice]
    let metraChoices: [HomeTripMetraChoice]
    let intercampusChoices: [HomeTripIntercampusChoice]
}

private struct HomeTripBoardingAccess: Hashable {
    enum Kind: Hashable {
        case train(stationId: Int)
        case bus(stopId: Int)
        case metra(stationId: String)
    }

    let kind: Kind
    let title: String
    let destinationKey: String
    let directDistanceMeters: Double
}

private struct HomeTripTrainChoice: Identifiable, Hashable {
    let line: LineColor
    let stationId: Int
    let stationName: String
    let destinationName: String?
    let distanceMeters: Double
    let legIndex: Int

    var id: String { "train-\(legIndex)-\(line.rawValue)-\(stationId)" }

    var displayLabel: String {
        let destination = destinationName.map { " → \($0)" } ?? ""
        return "\(line.shortName) · \(stationName)\(destination)"
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

private struct HomeTripIntercampusChoice: Identifiable, Hashable {
    let direction: IntercampusDirection
    let stopId: String
    let stopName: String
    let destinationName: String?
    let distanceMeters: Double
    let legIndex: Int

    var id: String {
        "intercampus-\(legIndex)-\(direction.rawValue)-\(stopId)"
    }

    var displayLabel: String {
        "\(direction.label) · \(stopName)"
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
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
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
                            isSelected ? .clear : ChicagoPalette.Gray.light.opacity(0.34),
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
                        isPinned ? line.swiftUIColor : ChicagoPalette.Gray.light.opacity(0.34),
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
    let accessTime: AccessTimeSummary
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
                        isSelected ? .clear : ChicagoPalette.Gray.light.opacity(0.34),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.name), \(accessibilityTimeLabel)")
    }

    private var secondaryLabel: String {
        AccessTimeFormatter.short(accessTime)
    }

    private var accessibilityTimeLabel: String {
        AccessTimeFormatter.accessibility(accessTime)
    }
}

private struct BusStopChip: View {
    let stop: BusStop
    let accessTime: AccessTimeSummary
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
                Text(AccessTimeFormatter.short(accessTime))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
                        isSelected ? .clear : ChicagoPalette.Gray.light.opacity(0.34),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stop.name), \(AccessTimeFormatter.accessibility(accessTime))")
    }
}

private struct MetraStationChip: View {
    let station: MetraStation
    let accessTime: AccessTimeSummary
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
                Text(AccessTimeFormatter.short(accessTime))
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
                        isSelected ? .clear : ChicagoPalette.Gray.light.opacity(0.34),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(station.name), \(AccessTimeFormatter.accessibility(accessTime))")
    }
}

private struct IntercampusStopChip: View {
    let choice: IntercampusStopChoice
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.stop.name)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(isSelected ? .white : ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                Text(choice.walkTimeText)
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
                        isSelected ? .clear : ChicagoPalette.Gray.light.opacity(0.34),
                        lineWidth: ChicagoSpacing.Stroke.thin
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.stop.name), \(choice.accessibilityWalkTimeText)")
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
                    ChicagoPalette.Gray.light.opacity(0.34),
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

private enum NearbyTransitCatchability {
    static let boardingBuffer: TimeInterval = 60
}

private enum DistanceFormatter {
    static func short(_ meters: Double) -> String {
        if meters < 1_000 {
            return "\(Int(meters)) m"
        } else {
            return String(format: "%.1f km", meters / 1_000)
        }
    }
}

private struct AccessTimeSummary {
    let walkingTravelTime: TimeInterval
    let isApproximateWalkingTime: Bool
    let cyclingTravelTime: TimeInterval?
}

private enum AccessTimeFormatter {
    private static let walkingMetersPerMinute = 84.0
    private static let cyclingMetersPerMinute = 250.0
    private static let minimumCyclingDisplayTime: TimeInterval = 2 * 60

    static func approximateWalkingTravelTime(distanceMeters: Double) -> TimeInterval {
        (distanceMeters / walkingMetersPerMinute) * 60
    }

    static func approximateCyclingTravelTime(distanceMeters: Double) -> TimeInterval {
        (distanceMeters / cyclingMetersPerMinute) * 60
    }

    static func short(_ summary: AccessTimeSummary) -> String {
        let walkMinutes = minutes(for: summary.walkingTravelTime)
        let walkPrefix = summary.isApproximateWalkingTime ? "≈" : ""
        let walking = "\(walkPrefix)\(walkMinutes) min walk"
        guard let cycling = summary.cyclingTravelTime,
              cycling >= minimumCyclingDisplayTime
        else {
            return walking
        }
        return "\(walking) / \(minutes(for: cycling)) min bike"
    }

    static func accessibility(_ summary: AccessTimeSummary) -> String {
        let walkMinutes = minutes(for: summary.walkingTravelTime)
        let walking = "\(summary.isApproximateWalkingTime ? "about " : "")\(minuteText(walkMinutes)) walk"
        guard let cycling = summary.cyclingTravelTime,
              cycling >= minimumCyclingDisplayTime
        else {
            return walking
        }
        return "\(walking), \(minuteText(minutes(for: cycling))) bike ride"
    }

    private static func minutes(for travelTime: TimeInterval) -> Int {
        max(1, Int((travelTime / 60).rounded()))
    }

    private static func minuteText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

// MARK: - Trip Divvy row

private struct TripDivvyContextRow: View {
    let originStations: [TripDivvyStationPick]
    let freeFloatingBikeCount: Int?
    let destinationDockStations: [TripDivvyStationPick]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ChicagoSpacing.xs) {
                if originStations.isEmpty {
                    TripDivvyContextChip(
                        systemImage: "bicycle",
                        count: 0,
                        unit: "e-bikes",
                        title: "Start",
                        detail: "none within 400 m",
                        isMuted: true
                    )
                } else {
                    ForEach(originStations) { pick in
                        TripDivvyContextChip(
                            systemImage: "bicycle",
                            count: pick.station.eBikesAvailable,
                            unit: pick.station.eBikesAvailable == 1 ? "e-bike" : "e-bikes",
                            title: pick.station.name,
                            detail: "\(pick.walkingMinutes) min walk",
                            isMuted: false
                        )
                    }
                }

                if let freeFloatingBikeCount {
                    TripDivvyContextChip(
                        systemImage: "bicycle.circle",
                        count: freeFloatingBikeCount,
                        unit: "free",
                        title: "Nearby",
                        detail: freeFloatingBikeCount == 1 ? "curb e-bike" : "curb e-bikes",
                        isMuted: freeFloatingBikeCount == 0
                    )
                }

                if destinationDockStations.isEmpty {
                    TripDivvyContextChip(
                        systemImage: "parkingsign.circle",
                        count: 0,
                        unit: "docks",
                        title: "Destination",
                        detail: "none within 400 m",
                        isMuted: true
                    )
                } else {
                    ForEach(destinationDockStations) { pick in
                        TripDivvyContextChip(
                            systemImage: "parkingsign.circle",
                            count: pick.station.docksAvailable,
                            unit: pick.station.docksAvailable == 1 ? "dock" : "docks",
                            title: pick.station.name,
                            detail: "\(pick.walkingMinutes) min walk",
                            isMuted: false
                        )
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TripDivvyContextChip: View {
    let systemImage: String
    let count: Int
    let unit: String
    let title: String
    let detail: String
    let isMuted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: ChicagoSpacing.xs) {
                Image(systemName: systemImage)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(iconColor)
                Text("\(count)")
                    .font(ChicagoTypography.displayMD(relativeTo: .title3))
                    .monospacedDigit()
                    .foregroundStyle(numberColor)
                Text(unit)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(title)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(detail)
                .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                .foregroundStyle(ChicagoPalette.Gray.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, ChicagoSpacing.sm)
        .padding(.vertical, ChicagoSpacing.xs)
        .frame(width: 150, height: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
                .fill(isMuted ? ChicagoPalette.Surface.elevated : ChicagoPalette.Mode.divvy.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm)
                .strokeBorder(borderColor, lineWidth: ChicagoSpacing.Stroke.thin)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(unit), \(title), \(detail)")
    }

    private var iconColor: Color {
        isMuted ? ChicagoPalette.Gray.medium : ChicagoPalette.Mode.divvy
    }

    private var numberColor: Color {
        isMuted ? ChicagoPalette.Gray.medium : ChicagoPalette.Gray.darkest
    }

    private var textColor: Color {
        isMuted ? ChicagoPalette.Gray.medium : ChicagoPalette.Gray.darkest
    }

    private var borderColor: Color {
        isMuted ? ChicagoPalette.Gray.light.opacity(0.34) : ChicagoPalette.Mode.divvy.opacity(0.35)
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
                        .foregroundStyle(ChicagoPalette.Mode.divvy)
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
                    .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
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
