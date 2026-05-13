import SwiftUI
import MapKit
import TransitDomain
import TransitModels
import TransitUI

/// Modal sheet opened from the dashboard. Lets the user pick a destination
/// (typing or tapping the map), runs `MKDirections.calculate(.transit)`, and
/// renders the decomposed legs with "Pin this" buttons that write back into
/// `UserRoutePreferences` so live tracking starts immediately.
struct TripPlannerScreen: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var suggestions: [DestinationSuggestion] = []
    @State private var pickedDestination: ResolvedDestination?
    @State private var pickerMode: PickerMode = .search
    @State private var mapCoordinate: CLLocationCoordinate2D?
    @State private var visibleCenter: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .region(.chicagoLoop)

    @State private var plans: [TripPlan] = []
    @State private var planError: String?
    @State private var isPlanning: Bool = false

    @State private var search: TripDestinationSearch = TripDestinationSearch(region: .chicagoLoop)
    @State private var suggestionsTask: Task<Void, Never>?
    @State private var debounceTask: Task<Void, Never>?
    @State private var resolveTask: Task<Void, Never>?

    private let planner = TripPlanner()

    enum PickerMode: String, Hashable, CaseIterable {
        case search
        case map

        var label: String {
            switch self {
            case .search: "Search"
            case .map: "Pick on map"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Destination mode", selection: $pickerMode) {
                    ForEach(PickerMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top)

                switch pickerMode {
                case .search: searchSection
                case .map: mapPickerSection
                }

                Divider()

                planButton
                    .padding()

                resultsSection
                    .frame(maxHeight: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Plan a trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await observeSuggestions() }
            .onDisappear {
                suggestionsTask?.cancel()
                debounceTask?.cancel()
                resolveTask?.cancel()
            }
        }
    }

    // MARK: - Search section

    @ViewBuilder
    private var searchSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Where to?", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                        suggestions = []
                        pickedDestination = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .onChange(of: query) { _, newValue in
                scheduleQuery(newValue)
            }

            if let picked = pickedDestination {
                pickedRow(picked)
                    .padding(.horizontal)
            } else if !suggestions.isEmpty {
                suggestionList
            } else if !query.isEmpty {
                Text("No matches yet…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 4)
    }

    private var suggestionList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.subheadline.weight(.medium))
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func pickedRow(_ picked: ResolvedDestination) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(picked.title).font(.subheadline.weight(.semibold))
                if !picked.subtitle.isEmpty {
                    Text(picked.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                pickedDestination = nil
                query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Map picker section

    private var mapPickerSection: some View {
        VStack(spacing: 8) {
            Map(position: $cameraPosition) {
                if let coordinate = mapCoordinate {
                    Marker("Destination", coordinate: coordinate).tint(.orange)
                }
                UserAnnotation()
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onMapCameraChange { context in
                visibleCenter = context.region.center
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            HStack {
                Button {
                    centerOnUser()
                } label: {
                    Label("My location", systemImage: "location.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    captureCurrentCenter()
                } label: {
                    Label("Drop pin here", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let coord = mapCoordinate {
                Text(String(format: "Pinned at %.4f, %.4f", coord.latitude, coord.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Center the map on a destination, then tap \"Drop pin here.\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Plan button

    private var planButton: some View {
        Button {
            runPlan()
        } label: {
            HStack {
                if isPlanning {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                }
                Text(isPlanning ? "Planning…" : "Plan transit route")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canPlan || isPlanning)
    }

    private var canPlan: Bool {
        guard model.location.lastKnown != nil else { return false }
        return destinationCoordinate != nil
    }

    private var destinationCoordinate: PlannerCoordinate? {
        if pickerMode == .search, let picked = pickedDestination {
            return picked.coordinate
        }
        if pickerMode == .map, let coord = mapCoordinate {
            return PlannerCoordinate(latitude: coord.latitude, longitude: coord.longitude)
        }
        return nil
    }

    // MARK: - Results section

    @ViewBuilder
    private var resultsSection: some View {
        if let error = planError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else if !plans.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(plans.enumerated()), id: \.offset) { _, plan in
                        planSection(plan)
                    }
                }
                .padding()
            }
        } else if model.location.lastKnown == nil {
            Text("Waiting for a location fix to use as your starting point…")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            Text("Pick a destination and tap Plan transit route.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    private func planSection(_ plan: TripPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            planKindLabel(for: plan)
            planHeader(plan)
            ForEach(plan.legs) { leg in
                TripLegRow(leg: leg) { pin(leg) }
            }
        }
    }

    @ViewBuilder
    private func planKindLabel(for plan: TripPlan) -> some View {
        let kind = planKind(plan)
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
            Text(kind.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func planKind(_ plan: TripPlan) -> (title: String, symbol: String, tint: Color) {
        let resolution = plan.legs
            .first(where: { $0.mode == .transit })?
            .transit?
            .resolution
        switch plan.flavor {
        case .train:
            if case .line(let color) = resolution {
                return ("Train · \(color.displayName)", "tram.fill", color.swiftUIColor)
            }
            return ("Train option", "tram.fill", .secondary)
        case .busShortestRide:
            if case .bus(let route) = resolution {
                return ("More walking · Route \(route)", "bus.fill", .indigo)
            }
            return ("More walking · less time on bus", "bus.fill", .indigo)
        case .busShortestWalk:
            if case .bus(let route) = resolution {
                return ("Less walking · Route \(route)", "bus.fill", .teal)
            }
            return ("Less walking · more time on bus", "bus.fill", .teal)
        case .standard:
            switch resolution {
            case .line(let color):
                return ("Train · \(color.displayName)", "tram.fill", color.swiftUIColor)
            case .bus(let route):
                return ("Bus · Route \(route)", "bus.fill", .indigo)
            case .unknown, .none:
                return ("Transit option", "arrow.triangle.swap", .secondary)
            }
        }
    }

    private func planHeader(_ plan: TripPlan) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDuration(plan.expectedTravelTime))
                    .font(.title3.weight(.semibold))
                if !plan.summary.isEmpty {
                    Text(plan.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(formatDistance(plan.totalDistanceMeters))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func scheduleQuery(_ newValue: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            search.setQuery(newValue)
        }
    }

    private func observeSuggestions() async {
        for await results in search.updates {
            if Task.isCancelled { break }
            suggestions = results
        }
    }

    private func pick(_ suggestion: DestinationSuggestion) {
        resolveTask?.cancel()
        suggestions = []
        query = suggestion.title
        resolveTask = Task { @MainActor in
            do {
                let resolved = try await search.resolve(suggestion)
                guard !Task.isCancelled else { return } 
                pickedDestination = resolved
                cameraPosition = .camera(MapCamera(
                    centerCoordinate: CLLocationCoordinate2D(
                        latitude: resolved.coordinate.latitude,
                        longitude: resolved.coordinate.longitude
                    ),
                    distance: 1_500
                ))
            } catch {
                planError = error.localizedDescription
            }
        }
    }

    private func centerOnUser() {
        if let last = model.location.lastKnown {
            let coord = CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            cameraPosition = .camera(MapCamera(centerCoordinate: coord, distance: 1_500))
        }
    }

    private func captureCurrentCenter() {
        mapCoordinate = visibleCenter
        pickedDestination = nil
    }

    private func runPlan() {
        guard let last = model.location.lastKnown else { return }
        guard let destination = destinationCoordinate else { return }
        let origin = PlannerCoordinate(latitude: last.latitude, longitude: last.longitude)
        isPlanning = true
        planError = nil
        plans = []
        Task { @MainActor in
            do {
                let result = try await planner.plan(from: origin, to: destination)
                if Task.isCancelled { return }
                plans = result
                isPlanning = false
            } catch {
                plans = []
                planError = error.localizedDescription
                isPlanning = false
            }
        }
    }

    private func pin(_ leg: TripLeg) {
        guard let transit = leg.transit else { return }
        switch transit.resolution {
        case .line(let color):
            model.saveManualRoutePreferences {
                $0.pinnedLine = color
                $0.pinnedStationId = nil
                $0.pinnedTrainDestination = nil
            }
        case .bus(let route):
            model.saveManualRoutePreferences {
                $0.pinnedBusRoute = route
                $0.pinnedBusDirection = nil
            }
        case .unknown:
            return
        }
        dismiss()
        Task { @MainActor in
            await model.refreshIfNeeded(force: true)
        }
    }

    // MARK: - Formatters

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1_000)
    }
}

// MARK: - Leg row

private struct TripLegRow: View {
    let leg: TripLeg
    let onPin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 4) {
                titleView
                if !leg.instructions.isEmpty {
                    Text(leg.instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(distanceText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            pinButtonIfApplicable
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var iconBadge: some View {
        let style = badgeStyle
        return Image(systemName: style.symbol)
            .font(.title3)
            .foregroundStyle(style.tint)
            .frame(width: 36, height: 36)
            .background(style.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var badgeStyle: (symbol: String, background: Color, tint: Color) {
        switch leg.mode {
        case .walking:
            return ("figure.walk", Color(uiColor: .tertiarySystemFill), .secondary)
        case .transit:
            switch leg.transit?.resolution {
            case .line(let c): return ("tram.fill", c.swiftUIColor, c.contrastingText)
            case .bus: return ("bus.fill", .indigo, .white)
            default: return ("arrow.triangle.swap", Color(uiColor: .tertiarySystemFill), .secondary)
            }
        case .other:
            return ("car.fill", Color(uiColor: .tertiarySystemFill), .secondary)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        switch (leg.mode, leg.transit?.resolution) {
        case (.walking, _):
            HStack(spacing: 8) {
                Text("Walk").font(.subheadline.weight(.semibold))
                Text(distanceText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case (.transit, .line(let c)?):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(c.swiftUIColor).frame(width: 12, height: 12)
                Text(c.displayName).font(.subheadline.weight(.semibold))
            }
        case (.transit, .bus(let r)?):
            Text("Route \(r)").font(.subheadline.weight(.semibold))
        case (.transit, .unknown(let raw)?):
            Text(raw).font(.subheadline.weight(.semibold))
        case (.transit, nil):
            Text("Transit").font(.subheadline.weight(.semibold))
        case (.other, _):
            Text(leg.instructions.isEmpty ? "Continue" : leg.instructions)
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var pinButtonIfApplicable: some View {
        if let resolution = leg.transit?.resolution {
            switch resolution {
            case .line(let c):
                pinButton(tint: c.swiftUIColor)
            case .bus:
                pinButton(tint: .indigo)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func pinButton(tint: Color) -> some View {
        Button(action: onPin) {
            Label("Pin", systemImage: "pin.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.small)
    }

    private var distanceText: String {
        if leg.distanceMeters < 1_000 {
            return "\(Int(leg.distanceMeters)) m"
        }
        return String(format: "%.1f km", leg.distanceMeters / 1_000)
    }
}
