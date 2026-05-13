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
    @State private var isTripPlannerPresented: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                    alertsCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Cozy Fox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { await model.refreshIfNeeded(force: true) }
            .onAppear { reloadPinnedFromPreferences() }
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
    }

    private var tripPlannerCard: some View {
        Button {
            isTripPlannerPresented = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan a trip").font(.headline)
                    Text("Search a destination and let Apple Maps pick the legs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live updates toggle

    private var liveUpdatesBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(liveStatusDotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.liveUpdatesActive ? "Live updates on" : "Live updates off")
                    .font(.subheadline.weight(.semibold))
                Text(liveStatusDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Live updates", isOn: Binding(
                get: { model.liveUpdatesEnabled },
                set: { model.setLiveUpdatesEnabled($0) }
            ))
            .labelsHidden()
            .disabled(model.isLowPowerMode)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveStatusDotColor: Color {
        if model.isLowPowerMode { return .orange }
        return model.liveUpdatesEnabled ? .green : .gray
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
        HStack(spacing: 8) {
            Image(systemName: model.location.context == .atHome ? "house.fill"
                  : model.location.context == .atWork ? "building.2.fill"
                  : "figure.walk")
            Text(directionDescription)
                .font(.subheadline.weight(.medium))
            Spacer()
            if model.isRefreshing { ProgressView().scaleEffect(0.7) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var directionDescription: String {
        switch model.location.context {
        case .atHome: "Heading to work"
        case .atWork: "Heading home"
        case .elsewhere: "Out and about"
        case .unknown: "Pick a direction"
        }
    }

    // MARK: - Train line picker

    private var linePickerCard: some View {
        Card(title: "Pin an L line", systemImage: "tram.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pinnedLineCard(line: LineColor) -> some View {
        Card(title: line.displayName, systemImage: "tram.fill") {
            pinnedLineBody(line: line)
        }
    }

    @ViewBuilder
    private func pinnedLineBody(line: LineColor) -> some View {
        if let origin {
            let stations = NearestStationResolver(maxDistanceMeters: 10_000)
                .closestStations(
                    onLine: line,
                    to: origin,
                    limit: 3,
                    catalog: LStationCatalog.all,
                    excludingStationIds: closedStationIds
                )

            if stations.isEmpty {
                Text("No \(line.displayName) station within 10 km of your location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let chosenId = effectivePinnedStation(stations: stations)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick a stop")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(stations, id: \.station.id) { entry in
                                StationChip(
                                    station: entry.station,
                                    distance: entry.distance,
                                    isSelected: entry.station.id == chosenId,
                                    accent: line.swiftUIColor,
                                    action: { setPinnedStation(entry.station.id) }
                                )
                            }
                        }
                    }
                    if let chosen = stations.first(where: { $0.station.id == chosenId }) {
                        directionPickerForTrain(at: chosen.station, line: line)
                        arrivalsByDirection(at: chosen.station, line: line)
                        trainProgressStrip(toStation: chosen.station, line: line)
                    }
                }
            }
        } else {
            Text("Waiting for a location fix…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Direction chips for the train pinned at this station — each chip is
    /// one of the CTA `destNm` values we've actually seen in arrivals (so
    /// only directions that are currently running show up). Tapping a chip
    /// pins that direction; tapping the active one unpins.
    @ViewBuilder
    private func directionPickerForTrain(at station: LStation, line: LineColor) -> some View {
        let destinations = Array(Set(
            model.snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == station.id }
                .map(\.destinationName)
        )).sorted()
        if destinations.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick a direction")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
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

    /// Group arrivals at this station by destination so the user can see
    /// both directions (e.g. "→ Howard … → 95th") side by side. When a
    /// destination is pinned, only that group is rendered.
    @ViewBuilder
    private func arrivalsByDirection(at station: LStation, line: LineColor) -> some View {
        let arrivals: [Arrival] = {
            let base = model.snapshot.trainArrivals
                .filter { $0.line == line && $0.stationId == station.id }
            if let pinned = pinnedTrainDestination {
                return base.filter { $0.destinationName == pinned }
            }
            return base
        }()
        let grouped = Dictionary(grouping: arrivals, by: \.destinationName)
            .sorted { $0.key < $1.key }
        if arrivals.isEmpty {
            Text(model.isRefreshing
                 ? "Fetching arrivals…"
                 : "No upcoming \(line.displayName) arrivals returned by CTA.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(grouped, id: \.key) { dest, times in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("→ \(dest)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        let summary = times
                            .sorted { $0.arrivalAt < $1.arrivalAt }
                            .prefix(3)
                            .map { ArrivalFormatter.label(for: $0).shortText }
                            .joined(separator: " · ")
                        Text(summary)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.primary)
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
        pinnedStationId = nil          // station + direction don't carry across lines
        pinnedTrainDestination = nil
        var prefs = model.preferences.loadRoutePreferences()
        prefs.pinnedLine = newValue
        prefs.pinnedStationId = nil
        prefs.pinnedTrainDestination = nil
        model.preferences.saveRoutePreferences(prefs)
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setPinnedStation(_ id: Int) {
        pinnedStationId = id
        pinnedTrainDestination = nil   // direction depends on the station — clear it
        var prefs = model.preferences.loadRoutePreferences()
        prefs.pinnedStationId = id
        prefs.pinnedTrainDestination = nil
        model.preferences.saveRoutePreferences(prefs)
        Task { await model.refreshIfNeeded(force: true) }
    }

    /// Live-position strip — locks onto the *specific* train that's predicted
    /// to arrive next at the selected station (by run number) so the strip
    /// and the "N min" label always describe the same vehicle. Falls back
    /// to closest-matching-direction only if the run number's position
    /// hasn't been fetched yet.
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
            // Preferred: the exact run that's predicted to arrive next.
            if let runId = pinnedArrival?.runNumber,
               let exact = model.vehiclePositions
                .first(where: { $0.id == runId && $0.mode == .train })
            {
                return [(exact, Distance.meters(from: stationCoord, to: (exact.latitude, exact.longitude)))]
            }
            // Fallback: any train on this line going the right direction.
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
            VehicleProgressStrip(
                distanceMeters: closest.1,
                scaleMeters: max(closest.1, 1_500),
                accent: line.swiftUIColor,
                vehicleLabel: closest.0.destinationName.map { "→ \($0)" } ?? "Train",
                stopLabel: station.name,
                intermediateStops: intermediate
            )
        }
    }

    /// Bus version — locks onto the *specific* vehicle whose `vid` matches
    /// the next predicted arrival at this stop. Without this match, a bus
    /// that just passed the stop heading further north on the same route
    /// could be picked as "closest", showing a misleading 200 m strip
    /// while the actual next bus is still minutes out.
    @ViewBuilder
    private func busProgressStrip(toStop stop: BusStop, route: String) -> some View {
        let stopCoord = (lat: stop.latitude, lon: stop.longitude)
        let stopPredictions = model.snapshot.busPredictions
            .filter { $0.route == route && $0.stopId == stop.id }
            .sorted { $0.arrivalAt < $1.arrivalAt }
        let nextVid = stopPredictions.first?.vehicleId
        let arrivingDestinations = Set(stopPredictions.map(\.destinationName))

        let candidates: [(VehiclePosition, Double)] = {
            // Preferred: the vehicle whose vid is named in the next prediction.
            if let vid = nextVid,
               let exact = model.vehiclePositions
                .first(where: { $0.id == vid && $0.mode == .bus })
            {
                return [(exact, Distance.meters(from: stopCoord, to: (exact.latitude, exact.longitude)))]
            }
            // Fallback: any bus on this route with a matching destination.
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
            // Use only stops on this route in the *same direction* as our
            // selected stop so we don't tick the opposite-side stops.
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
            VehicleProgressStrip(
                distanceMeters: closest.1,
                scaleMeters: max(closest.1, 1_500),
                accent: .orange,
                vehicleLabel: closest.0.destinationName.map { "→ \($0)" } ?? "Bus",
                stopLabel: stop.directionLabel.isEmpty ? stop.name : stop.directionLabel,
                intermediateStops: intermediate
            )
        }
    }

    /// Stops on the route that lie *between* the vehicle and the user's stop,
    /// each annotated with a `fraction ∈ [0, 1]` measuring progress along the
    /// vehicle→user direction (0 = at the vehicle, 1 = at the user's stop).
    ///
    /// **Why projection, not Haversine.** Earlier the fraction was just
    /// `d(vehicle, stop) / d(vehicle, user)`, which orders stops by *radial*
    /// distance — wrong for routes that aren't a straight line. On 147 NB it
    /// put Chestnut "before" Ontario because both are north of the vehicle
    /// but Chestnut is *slightly* closer in straight-line distance for some
    /// vehicle positions. Projection onto the V→U axis fixes ordering: a stop
    /// farther north along the route gets a higher fraction regardless of any
    /// east/west jog the route takes in between.
    private func intermediateStops(
        vehicle: (lat: Double, lon: Double),
        userStop: (lat: Double, lon: Double),
        candidates: [(name: String, lat: Double, lon: Double)],
        limit: Int? = nil
    ) -> [RouteStopTick] {
        let total = Distance.meters(from: vehicle, to: userStop)
        guard total > 50 else { return [] }     // too close to bother

        // V→U vector in lat/lon space and its squared magnitude (we never
        // need the actual magnitude — `(dot / |V|²) * V` gives the
        // projection, and we just want the scalar coefficient).
        let dLat = userStop.lat - vehicle.lat
        let dLon = userStop.lon - vehicle.lon
        let normSq = dLat * dLat + dLon * dLon
        guard normSq > 0 else { return [] }

        let tolerance = max(300.0, total * 0.20)

        let ticks: [RouteStopTick] = candidates.compactMap { stop in
            let dVehicle = Distance.meters(from: vehicle, to: (stop.lat, stop.lon))
            let dUser    = Distance.meters(from: userStop, to: (stop.lat, stop.lon))
            // Loose triangle-inequality filter keeps stops near the V→U line
            // while still tolerating a route that curves.
            guard dVehicle < total, dUser < total else { return nil }
            guard dVehicle + dUser <= total + tolerance else { return nil }

            // Vector projection: scalar coefficient of (stop - vehicle) onto
            // (userStop - vehicle). 0 at the vehicle, 1 at the user's stop,
            // and the value increases monotonically as you walk along the
            // route's general direction.
            let sdLat = stop.lat - vehicle.lat
            let sdLon = stop.lon - vehicle.lon
            let dot = sdLat * dLat + sdLon * dLon
            let projection = max(0, min(1, dot / normSq))
            return RouteStopTick(label: stop.name, fraction: projection)
        }

        let sorted = ticks.sorted { $0.fraction < $1.fraction }
        if let limit, sorted.count > limit {
            // Keep the N stops closest to the user's stop — those are the
            // "approach" stops the vehicle is about to hit. Higher `fraction`
            // = closer to the user's stop.
            return Array(sorted.suffix(limit))
        }
        return sorted
    }

    /// Tap a direction chip to pin that destination; tap the active one to
    /// unpin and see all directions again.
    private func togglePinnedTrainDestination(_ destination: String) {
        let newValue: String? = (pinnedTrainDestination == destination) ? nil : destination
        pinnedTrainDestination = newValue
        var prefs = model.preferences.loadRoutePreferences()
        prefs.pinnedTrainDestination = newValue
        model.preferences.saveRoutePreferences(prefs)
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bus route picker

    private var busRoutePickerCard: some View {
        Card(title: "Pin a bus route", systemImage: "bus.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Menu {
                        if pinnedBusRoute != nil {
                            Button("Unpin", role: .destructive) { setPinnedBus(nil) }
                            Divider()
                        }
                        ForEach(BusStopCatalog.allRoutes, id: \.self) { route in
                            Button("Route \(route)") { setPinnedBus(route) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bus.fill")
                            Text(pinnedBusRoute.map { "Route \($0)" } ?? "Choose a route")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.primary)
                    }
                }
                Text("Tap \"Plan a trip\" below to auto-pin a route from a destination.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pinnedBusCard(route: String) -> some View {
        Card(title: "Route \(route)", systemImage: "bus.fill") {
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
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
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Direction chips for a pinned bus route. Tap to pin one of the
    /// dominant directions; tap the active one again to unpin and see both.
    @ViewBuilder
    private func directionPickerForBus(route: String, stops: [BusStop]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick a direction")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stops) { stop in
                        DirectionChip(
                            label: stop.directionLabel.isEmpty ? stop.name : stop.directionLabel,
                            isSelected: pinnedBusDirection == stop.directionLabel,
                            accent: Color.orange,
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
            .prefix(3)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stop.directionLabel.isEmpty ? stop.name : stop.directionLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(DistanceFormatter.short(distance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(stop.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if predictions.isEmpty {
                Text(model.isRefreshing
                     ? "Fetching predictions…"
                     : "No upcoming buses returned by CTA.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(predictions), id: \.id) { p in
                    Text("→ \(p.destinationName) · \(ArrivalFormatter.label(for: p).shortText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            busProgressStrip(toStop: stop, route: route)
        }
    }

    private func setPinnedBus(_ route: String?) {
        pinnedBusRoute = route
        pinnedBusDirection = nil    // direction depends on the route — clear it
        var prefs = model.preferences.loadRoutePreferences()
        prefs.pinnedBusRoute = route
        prefs.pinnedBusDirection = nil
        model.preferences.saveRoutePreferences(prefs)
        Task { await model.refreshIfNeeded(force: true) }
    }

    /// Tap a direction chip to pin that bus direction; tap the active one
    /// to unpin and see both directions again.
    private func togglePinnedBusDirection(_ direction: String) {
        let newValue: String? = (pinnedBusDirection == direction) ? nil : direction
        pinnedBusDirection = newValue
        var prefs = model.preferences.loadRoutePreferences()
        prefs.pinnedBusDirection = newValue
        model.preferences.saveRoutePreferences(prefs)
        Task { await model.refreshIfNeeded(force: true) }
    }

    // MARK: - Bikes

    private var bikeCard: some View {
        Card(title: "Closest e-bike", systemImage: "bicycle") {
            BikeBlockView(pick: model.snapshot.nearestBike)
                .frame(height: 120)
        }
        .onTapGesture {
            model.activeDetail = .bikeNearest
        }
    }

    // MARK: - Near You (deduped by line / by route)

    private var nearYouSection: some View {
        Card(title: "Near you", systemImage: "location.fill") {
            VStack(alignment: .leading, spacing: 14) {
                if model.location.lastKnown == nil {
                    Text("Waiting for a location fix…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if !nearbyLines.isEmpty {
                        Label("L lines within walking distance",
                              systemImage: "tram.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(nearbyLines) { entry in
                            LineRow(
                                entry: entry,
                                arrivals: arrivals(forLine: entry.line, station: entry.station)
                            )
                        }
                    } else {
                        Text("No L lines within 1.5 km")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    if !nearbyBusRoutes.isEmpty {
                        HStack(spacing: 4) {
                            Label("Bus routes nearby", systemImage: "bus.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("tap to pin")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(nearbyBusRoutes) { entry in
                            BusStopRow(
                                stop: entry.stop,
                                distance: entry.distance,
                                predictions: predictions(for: entry.stop)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { setPinnedBus(entry.stop.route) }
                        }
                    } else {
                        Text("No bus routes within 1.5 km")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Derived "nearby" lists

    private var origin: (lat: Double, lon: Double)? {
        guard let loc = model.location.lastKnown else { return nil }
        return (loc.latitude, loc.longitude)
    }

    /// Stations the live alerts feed marks as fully closed — excluded from
    /// every "nearby" recommendation below. Computed each render off the
    /// current snapshot (cheap; ~10 string scans).
    private var closedStationIds: Set<Int> {
        ClosedStationsAnalyzer.closedStationIds(from: model.snapshot.activeAlerts)
    }

    /// One entry per L line within walking distance, each at the nearest
    /// station serving that line. Pinned line is hidden from this list (it's
    /// already surfaced in its own card above).
    private var nearbyLines: [LineEntry] {
        guard let origin else { return [] }
        let stations = NearestStationResolver(maxDistanceMeters: 1_500)
            .all(
                within: 1_500,
                of: origin,
                catalog: LStationCatalog.all,
                excludingStationIds: closedStationIds
            )

        var byLine: [LineColor: (station: LStation, distance: Double)] = [:]
        for entry in stations {
            for line in entry.station.servedLines {
                if let existing = byLine[line], existing.distance <= entry.distance {
                    continue
                }
                byLine[line] = (entry.station, entry.distance)
            }
        }

        return byLine
            .filter { $0.key != pinnedLine }
            .map { LineEntry(line: $0.key, station: $0.value.station, distance: $0.value.distance) }
            .sorted { $0.distance < $1.distance }
    }

    /// One entry per nearby bus route (closest stop on each), excluding the
    /// pinned route. Up to 5 entries.
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
            .prefix(3)
            .map { $0 }
    }

    private func predictions(for stop: BusStop) -> [BusPrediction] {
        model.snapshot.busPredictions
            .filter { $0.stopId == stop.id && $0.route == stop.route }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Alerts

    /// Alerts narrowed to whatever the user has actually pinned. With nothing
    /// pinned we fall back to showing all active alerts so the dashboard isn't
    /// silent before the user makes a choice.
    private var relevantAlerts: [ServiceAlert] {
        var lines: Set<LineColor> = []
        if let line = pinnedLine { lines.insert(line) }

        var busRoutes: Set<String> = []
        if let route = pinnedBusRoute { busRoutes.insert(route) }

        return model.snapshot.activeAlerts.filtered(forLines: lines, busRoutes: busRoutes)
    }

    private var alertsCard: some View {
        let alerts = relevantAlerts
        if alerts.isEmpty {
            return AnyView(EmptyView())
        }
        let title = (pinnedLine != nil || pinnedBusRoute != nil)
            ? "Alerts on your pinned routes"
            : "Service alerts"
        return AnyView(
            Card(title: title, systemImage: "exclamationmark.triangle.fill") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(alerts.prefix(3), id: \.id) { alert in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.headline).font(.subheadline.weight(.medium))
                            Text(alert.shortDescription).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        )
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

// MARK: - Row views

private struct LineRow: View {
    let entry: LineEntry
    let arrivals: [Arrival]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(entry.line.swiftUIColor)
                    .frame(width: 16, height: 16)
                Text(entry.line.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(DistanceFormatter.short(entry.distance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.station.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            if arrivals.isEmpty {
                Text("No upcoming arrivals")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(arrivals, id: \.id) { a in
                    Text("→ \(a.destinationName) · \(ArrivalFormatter.label(for: a).shortText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BusStopRow: View {
    let stop: BusStop
    let distance: Double
    let predictions: [BusPrediction]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(stop.route)")
                    .font(.subheadline.weight(.semibold))
                Text(stop.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(DistanceFormatter.short(distance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !stop.directionLabel.isEmpty {
                Text(stop.directionLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if predictions.isEmpty {
                Text("No predictions fetched")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(predictions, id: \.id) { p in
                    Text("→ \(p.destinationName) · \(ArrivalFormatter.label(for: p).shortText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StationChip: View {
    let station: LStation
    let distance: Double
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(DistanceFormatter.short(distance))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? accent.opacity(0.18) : Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// A stop on the route that lies between the vehicle and the user's stop.
/// `fraction` ∈ (0, 1) — distance from the vehicle divided by the total
/// vehicle→user-stop distance. Used to position a tick on the strip.
struct RouteStopTick: Hashable {
    let label: String
    let fraction: Double
}

/// 1-D representation of how far a live vehicle is from the user's chosen
/// boarding stop, with optional intermediate-stop ticks so the user can
/// tell whether the vehicle has already passed nearby stops.
///
///   ●━━╿━━╿━━╿━━╿━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╿
///   Train                                    Belmont
///
/// Tick density auto-adapts to the strip width — labels are dropped under
/// ~80 pt available width, ticks remain.
private struct VehicleProgressStrip: View {
    let distanceMeters: Double
    let scaleMeters: Double
    let accent: Color
    let vehicleLabel: String
    let stopLabel: String
    let intermediateStops: [RouteStopTick]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let clamped = min(max(distanceMeters, 0), scaleMeters)
                let progress = clamped / scaleMeters   // 0 = at stop, 1 = at scale max
                let dotX = geo.size.width * (1 - progress)

                ZStack(alignment: .topLeading) {
                    // --- 1-D track ---
                    Capsule()
                        .fill(Color.gray.opacity(0.25))
                        .frame(height: 3)
                        .position(x: geo.size.width / 2, y: 7)

                    // Intermediate stop ticks (geographically positioned).
                    ForEach(intermediateStops, id: \.self) { tick in
                        let stripX = dotX + (geo.size.width - dotX) * tick.fraction
                        Rectangle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 2, height: 8)
                            .position(x: stripX, y: 7)
                    }

                    // User-stop marker pinned to the right edge.
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3, height: 12)
                        .position(x: max(0, geo.size.width - 1.5), y: 7)

                    // Vehicle dot — drawn over the ticks so it sits on top.
                    Circle()
                        .fill(accent)
                        .frame(width: 11, height: 11)
                        .position(x: min(max(5.5, dotX), geo.size.width - 5.5),
                                  y: 7)

                    // --- Geographically-positioned tick labels ---
                    //
                    // Each label is rotated -30° (counter-clockwise) so
                    // adjacent labels stack diagonally instead of fighting
                    // for the same pixels. Anchored at center, then
                    // positioned with `.position` at the tick's x.
                    ForEach(intermediateStops, id: \.self) { tick in
                        let stripX = dotX + (geo.size.width - dotX) * tick.fraction
                        Text(tick.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .rotationEffect(.degrees(-30))
                            .position(x: stripX, y: 28)
                    }
                }
            }
            .frame(height: 46)  // 14 strip + ~32 for the angled labels

            HStack(spacing: 4) {
                Text("\(vehicleLabel) · \(formatDistance(distanceMeters)) out")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(stopLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func formatDistance(_ m: Double) -> String {
        if m < 1_000 { return "\(Int(m.rounded())) m" }
        return String(format: "%.1f km", m / 1_000)
    }
}

private struct DirectionChip: View {
    let label: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? accent.opacity(0.20) : Color.gray.opacity(0.12))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
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
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(line.swiftUIColor)
                    .frame(width: 14, height: 14)
                Text(line.shortName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPinned ? .primary : .secondary)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(line.swiftUIColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isPinned ? line.swiftUIColor.opacity(0.18) : Color.gray.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isPinned ? line.swiftUIColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
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

// MARK: - Card

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}
