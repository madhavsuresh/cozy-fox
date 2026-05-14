import ChicagoTheme
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
    @State private var pinSource: RoutePinSource = .manual
    @State private var isTripPlannerPresented: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    flagHeader
                    alertsCard
                    liveUpdatesBar
                    contextBanner
                    linePickerCard
                    if let line = pinnedLine {
                        pinnedLineCard(line: line)
                    }
                    busRoutePickerCard
                    if let route = pinnedBusRoute {
                        pinnedBusCard(route: route)
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
        pinSource = prefs.pinSource
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
            return "Polling CTA every 30 seconds for fresh delays"
        }
        return "Pull to refresh, or wait for background updates"
    }

    // MARK: - Context banner

    private var contextBanner: some View {
        HStack(spacing: ChicagoSpacing.sm) {
            Image(systemName: model.location.context == .atHome ? "house.fill"
                  : model.location.context == .atWork ? "building.2.fill"
                  : "figure.walk")
                .foregroundStyle(ChicagoPalette.flagBlue)
            Text(directionDescription)
                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
                .foregroundStyle(ChicagoPalette.Gray.darkest)
            if isAutopinned {
                Text("Autopin")
                    .font(ChicagoTypography.displaySM(relativeTo: .caption2))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, ChicagoSpacing.sm)
                    .padding(.vertical, 3)
                    .background(ChicagoPalette.flagBlue,
                                in: Capsule())
            }
            Spacer()
            if model.isRefreshing { ProgressView().scaleEffect(0.7) }
        }
        .padding(ChicagoSpacing.md)
        .background(ChicagoPalette.lakeMichigan,
                    in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md))
    }

    private var directionDescription: String {
        switch model.location.context {
        case .atHome: "Heading to work"
        case .atWork: "Heading home"
        case .elsewhere: "Heading home"
        case .unknown: "Pick a direction"
        }
    }

    private var isAutopinned: Bool {
        pinSource == .automatic && (pinnedLine != nil || pinnedBusRoute != nil)
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
            // Pull a wider candidate pool than we display so walking-aware
            // re-ranking has room to promote a stop that's further by air
            // but closer on foot. The display limit stays at 3 chips.
            let candidates = NearestStationResolver(maxDistanceMeters: 10_000)
                .closestStations(
                    onLine: line,
                    to: origin,
                    limit: 6,
                    catalog: LStationCatalog.all,
                    excludingStationIds: closedStationIds
                )

            if candidates.isEmpty {
                Text("No \(line.displayName) station within 10 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                let ranked = rankWithWalking(candidates: candidates, origin: origin)
                let stations = Array(ranked.prefix(3))
                let chosenId = effectivePinnedStation(
                    stations: stations.map { (station: $0.station, distance: $0.haversine) }
                )
                VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                    sectionLabel("Pick a stop")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: ChicagoSpacing.xs) {
                            ForEach(stations, id: \.station.id) { entry in
                                StationChip(
                                    station: entry.station,
                                    distance: entry.haversine,
                                    walkingTime: entry.walking?.expectedTravelTime,
                                    isSelected: entry.station.id == chosenId,
                                    accent: line.swiftUIColor,
                                    action: { setPinnedStation(entry.station.id) }
                                )
                            }
                        }
                    }
                    if let chosen = stations.first(where: { $0.station.id == chosenId }) {
                        directionPickerForTrain(at: chosen.station, line: line)
                        arrivalsHeadline(at: chosen.station, line: line)
                        trainProgressStrip(toStation: chosen.station, line: line)
                    }
                }
                .task(id: walkingTaskKey(line: line, origin: origin)) {
                    model.walkingResolver.ensureFresh(
                        origin: origin,
                        stations: candidates.map(\.station)
                    )
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                .foregroundStyle(ChicagoPalette.Gray.medium)
        }
    }

    /// Re-ranks candidates by walking distance where MapKit has answered,
    /// falling back to the resolver's effective distance (Haversine + river
    /// penalty) for entries that aren't cached yet. The displayed
    /// `haversine` value stays straight-line for the chip label.
    private func rankWithWalking(
        candidates: [(station: LStation, distance: Double)],
        origin: (lat: Double, lon: Double)
    ) -> [RankedStop] {
        let walkingResolver = model.walkingResolver
        return candidates
            .map { entry -> RankedStop in
                let walking = walkingResolver.cached(
                    origin: origin,
                    stationId: entry.station.id
                ) ?? walkingResolver.staleFallback(
                    origin: origin,
                    stationId: entry.station.id
                )
                let rankingMeters = walking?.meters ?? (
                    entry.distance + RiverPenalty.penalty(
                        from: origin,
                        to: (entry.station.latitude, entry.station.longitude)
                    )
                )
                return RankedStop(
                    station: entry.station,
                    haversine: entry.distance,
                    walking: walking,
                    rankingMeters: rankingMeters
                )
            }
            .sorted { $0.rankingMeters < $1.rankingMeters }
    }

    private func walkingTaskKey(line: LineColor, origin: (lat: Double, lon: Double)) -> String {
        // ~10m grid: enough precision to retrigger when the user actually
        // moves, coarse enough to avoid GPS-jitter thrashes mid-render.
        let lat = (origin.lat * 11000).rounded()
        let lon = (origin.lon * 11000).rounded()
        return "\(line.rawValue):\(lat):\(lon)"
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
        stations: [(station: LStation, distance: Double)]
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
            let directionalStops = NearestBusStopResolver(maxDistanceMeters: 5_000)
                .nearestPerDirection(onRoute: route, to: origin, catalog: BusStopCatalog.all)
            if directionalStops.isEmpty {
                Text("No Route \(route) stop within 5 km of your location.")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            } else {
                VStack(alignment: .leading, spacing: ChicagoSpacing.md) {
                    if directionalStops.count > 1 {
                        directionPickerForBus(route: route, stops: directionalStops)
                    }
                    let visibleStops: [BusStop] = {
                        guard let pinned = pinnedBusDirection else { return directionalStops }
                        let filtered = directionalStops.filter { $0.directionLabel == pinned }
                        return filtered.isEmpty ? directionalStops : filtered
                    }()
                    ForEach(visibleStops) { stop in
                        pinnedBusDirectionRow(route: route, stop: stop, origin: origin)
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
    private func directionPickerForBus(route: String, stops: [BusStop]) -> some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            sectionLabel("Pick a direction")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ChicagoSpacing.xs) {
                    ForEach(stops) { stop in
                        DirectionChip(
                            label: stop.directionLabel.isEmpty ? stop.name : stop.directionLabel,
                            isSelected: pinnedBusDirection == stop.directionLabel,
                            accent: ChicagoPalette.flagBlue,
                            action: { togglePinnedBusDirection(stop.directionLabel) }
                        )
                    }
                }
            }
        }
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
                Text(DistanceFormatter.short(distance))
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
        model.saveManualRoutePreferences {
            $0.pinnedBusRoute = route
            $0.pinnedBusDirection = nil
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func togglePinnedBusDirection(_ direction: String) {
        let newValue: String? = (pinnedBusDirection == direction) ? nil : direction
        pinnedBusDirection = newValue
        model.saveManualRoutePreferences {
            $0.pinnedBusDirection = newValue
        }
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bikes

    private var bikeCard: some View {
        ChicagoCard(title: "Closest e-bikes",
                    eyebrow: "Divvy",
                    ornament: .icon(systemName: "bicycle")) {
            let picks = model.snapshot.nearbyBikePicks
            if picks.isEmpty {
                Text("No e-bikes within walking distance")
                    .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: ChicagoSpacing.xs) {
                    ForEach(Array(picks.prefix(3).enumerated()), id: \.element.station.id) { index, pick in
                        BikeStationRow(pick: pick)
                        if index < min(picks.count, 3) - 1 {
                            Rectangle()
                                .fill(ChicagoPalette.cornflower.opacity(0.25))
                                .frame(height: ChicagoSpacing.Stroke.hairline)
                        }
                    }
                    if picks.count > 1 {
                        Button {
                            model.activeDetail = .bikeNearest
                        } label: {
                            HStack(spacing: ChicagoSpacing.xs) {
                                Text("See all on map")
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
                    if !nearbyLines.isEmpty || !nearbyBusRoutes.isEmpty {
                        Rectangle()
                            .fill(ChicagoPalette.cornflower.opacity(0.4))
                            .frame(height: ChicagoSpacing.Stroke.hairline)
                    }
                    nearbyBuses
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
        // resolver's effective-distance order. No new MapKit requests are
        // kicked off here — the "Near you" view is glanceable and we don't
        // want to fan out per-line walking queries on every refresh.
        let walkingResolver = model.walkingResolver
        let reranked: [(station: LStation, haversine: Double, rankingMeters: Double)] = stations
            .enumerated()
            .map { index, entry in
                let walking = walkingResolver.cached(
                    origin: origin,
                    stationId: entry.station.id
                )
                // Without a walking value, preserve the resolver's order via
                // a tiny additive `index` tiebreaker so equal Haversine
                // entries don't reshuffle on re-render.
                let ranking = walking?.meters ?? (entry.distance + Double(index) * 0.001)
                return (entry.station, entry.distance, ranking)
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

    // MARK: - Alerts

    private var relevantAlerts: [ServiceAlert] {
        var lines: Set<LineColor> = []
        if let line = pinnedLine { lines.insert(line) }

        var busRoutes: Set<String> = []
        if let route = pinnedBusRoute { busRoutes.insert(route) }

        return model.snapshot.activeAlerts.filtered(forLines: lines, busRoutes: busRoutes)
    }

    @ViewBuilder
    private var alertsCard: some View {
        let alerts = relevantAlerts
        if !alerts.isEmpty {
            let title = (pinnedLine != nil || pinnedBusRoute != nil)
                ? "Alerts on your pinned routes"
                : "Service alerts"
            ChicagoCard(title: title,
                        eyebrow: "Heads up",
                        ornament: .star) {
                VStack(alignment: .leading, spacing: ChicagoSpacing.sm) {
                    ForEach(alerts.prefix(3), id: \.id) { alert in
                        AlertRow(alert: alert,
                                 pinnedLine: pinnedLine,
                                 pinnedBusRoute: pinnedBusRoute)
                    }
                    Link(destination: ServiceAlert.detailsURL) {
                        HStack(spacing: 2) {
                            Text("Details on transitchicago.com")
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.bahama)
                    }
                    .accessibilityLabel("Open service alerts on transitchicago.com")
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

// MARK: - Alert row

private struct AlertRow: View {
    let alert: ServiceAlert
    let pinnedLine: LineColor?
    let pinnedBusRoute: String?

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
        } else if let line = alert.impactedLineColors.first {
            RouteBadge(line: line, size: .sm)
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
        } else if let line = alert.impactedLineColors.first {
            lineLabel = "\(line.displayName) line"
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

private struct RankedStop {
    let station: LStation
    let haversine: Double
    let walking: WalkingDistance?
    let rankingMeters: Double
}

private struct StationChip: View {
    let station: LStation
    let distance: Double
    let walkingTime: TimeInterval?
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
    }

    private var secondaryLabel: String {
        if let walkingTime {
            let minutes = max(1, Int((walkingTime / 60).rounded()))
            return "\(minutes) min walk"
        }
        return DistanceFormatter.short(distance)
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

// MARK: - Bike station row

private struct BikeStationRow: View {
    let pick: NearestBikePick

    var body: some View {
        Button(action: openInAppleMaps) {
            HStack(alignment: .center, spacing: ChicagoSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.station.name)
                        .font(ChicagoTypography.displaySM())
                        .foregroundStyle(ChicagoPalette.Gray.darkest)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(pick.walkingMinutes) min walk")
                        .font(ChicagoTypography.body(.regular, relativeTo: .footnote))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                }
                Spacer(minLength: ChicagoSpacing.sm)
                BigNumber(
                    pick.station.eBikesAvailable,
                    unit: pick.station.eBikesAvailable == 1 ? "e-bike" : "e-bikes",
                    size: .md,
                    tone: pick.station.isScarce ? .warning : .accent,
                    accessibilityLabel: "\(pick.station.eBikesAvailable) e-bikes available"
                )
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.vertical, ChicagoSpacing.xs)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pick.station.name), \(pick.walkingMinutes) minute walk, \(pick.station.eBikesAvailable) e-bikes available")
        .accessibilityHint("Opens this station in Apple Maps")
    }

    private func openInAppleMaps() {
        let coord = CLLocationCoordinate2D(
            latitude: pick.station.latitude,
            longitude: pick.station.longitude
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        item.name = pick.station.name
        item.openInMaps()
    }
}
