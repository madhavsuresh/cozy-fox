import ChicagoTheme
import SwiftUI
import MapKit
import TransitDomain
import TransitModels

struct SettingsScreen: View {
    @Environment(AppViewModel.self) private var model
    @State private var prefs: UserRoutePreferences = .empty
    @State private var anchors: CommuteAnchors = .empty
    @State private var trainKey: String = ""
    @State private var busKey: String = ""
    @State private var metraKey: String = ""
    @State private var showWorkEntry: Bool = false
    @State private var trainVerify: APIKeyCheck = .untested
    @State private var busVerify: APIKeyCheck = .untested
    @State private var metraVerify: APIKeyCheck = .untested
    @State private var isVerifying: Bool = false
    @State private var trainSaveStatus: String = "—"
    @State private var busSaveStatus: String = "—"
    @State private var metraSaveStatus: String = "—"
    @State private var learningDataVersion: Int = 0
    @State private var showResetLearningConfirmation: Bool = false

    var body: some View {
        Form {
            Section {
                SecureField("CTA Train Tracker key", text: $trainKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: trainKey) { _, newValue in
                        trainSaveStatus = saveAndRoundtrip(.trainTracker, value: newValue)
                        trainVerify = .untested
                    }
                Text("Train key: \(trainSaveStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusRow(for: trainVerify, label: "Train key")

                SecureField("CTA Bus Tracker key", text: $busKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: busKey) { _, newValue in
                        busSaveStatus = saveAndRoundtrip(.busTracker, value: newValue)
                        busVerify = .untested
                    }
                Text("Bus key: \(busSaveStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusRow(for: busVerify, label: "Bus key")

                SecureField("Metra GTFS key", text: $metraKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: metraKey) { _, newValue in
                        metraSaveStatus = saveAndRoundtrip(.metra, value: newValue)
                        metraVerify = .untested
                    }
                Text("Metra key: \(metraSaveStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                statusRow(for: metraVerify, label: "Metra key")

                Button("Reload from Keychain") {
                    reloadFromKeychain()
                }

                Button {
                    Task { await verifyKeys() }
                } label: {
                    HStack {
                        if isVerifying { ProgressView().scaleEffect(0.8) }
                        Text(isVerifying ? "Verifying…" : "Verify keys")
                    }
                }
                .disabled(isVerifying || (trainKey.isEmpty && busKey.isEmpty && metraKey.isEmpty))
            } header: {
                Text("API keys")
            } footer: {
                Text("Keys auto-save to the iOS Keychain on every keystroke; the status line below each field shows the round-trip read-back. Tap Verify to confirm each key is accepted by its transit API.")
                    .font(.footnote)
            }

            Section("Commute") {
                if let work = anchors.work {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Work")
                            .font(.subheadline.weight(.semibold))
                        Text(String(format: "%.4f, %.4f", work.latitude, work.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No work address set")
                        .foregroundStyle(.secondary)
                }
                Button(anchors.work == nil ? "Set work address" : "Edit work address") {
                    showWorkEntry = true
                }
                if anchors.work != nil {
                    Button("Clear work address", role: .destructive) {
                        anchors.work = nil
                        model.preferences.saveCommuteAnchors(anchors)
                        model.location.updateAnchors(anchors)
                    }
                }
            }

            visibilitySection

            Section {
                Toggle("Include free-floating e-bikes", isOn: Binding(
                    get: { prefs.includeFreeFloatingBikes },
                    set: { prefs.includeFreeFloatingBikes = $0; save(refresh: true) }
                ))
                Toggle("Auto-pin commute routes",
                       isOn: Binding(
                        get: { prefs.autopinEnabled },
                        set: { setAutopinEnabled($0) }
                       ))
                Toggle("Always show Live Activity",
                       isOn: Binding(
                        get: { prefs.alwaysShowLiveActivity },
                        set: { prefs.alwaysShowLiveActivity = $0; save() }
                       ))
                Toggle("Auto-start on leaving home/work",
                       isOn: Binding(
                        get: { prefs.autoStartLiveActivity },
                        set: { prefs.autoStartLiveActivity = $0; save() }
                       ))
                .disabled(prefs.alwaysShowLiveActivity)
                Toggle("Show nearby trains and buses",
                       isOn: Binding(
                        get: { prefs.nearbyDiscoveryEnabled },
                        set: { prefs.nearbyDiscoveryEnabled = $0; save(refresh: true) }
                       ))
            } header: {
                Text("Behavior")
            } footer: {
                Text("When off, the dashboard only fetches your pinned routes — tap “Show nearby” on the home screen to query nearby trains and buses on demand.")
            }

            Section("Tracked trains") {
                if prefs.trains.isEmpty {
                    Text("No train routes yet — add one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.trains) { pref in
                        VStack(alignment: .leading) {
                            Text("\(pref.line.displayName) · \(pref.stationName)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(pref.directionLabel) · \(pref.direction.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        prefs.trains.remove(atOffsets: offsets)
                        save()
                    }
                }
            }

            Section("Tracked buses") {
                if prefs.buses.isEmpty {
                    Text("No bus routes yet — add one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.buses) { pref in
                        VStack(alignment: .leading) {
                            Text("#\(pref.route) · \(pref.stopName)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(pref.directionLabel) · \(pref.direction.label)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        prefs.buses.remove(atOffsets: offsets)
                        save()
                    }
                }
            }

            Section("Privacy") {
                Text("Cozy Fox has no backend. Trains, buses, and Divvy data come from public Chicago APIs directly. Your API keys live in the iOS Keychain. Location is only used for region monitoring around home/work plus one-shot foreground reads.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                let profile = model.preferences.loadMobilityProfile()
                Text("Local learning data: \(profile.observations.count) context observations, \(profile.routeObservations.count) route observations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .id(learningDataVersion)
                Button("Clear local learning data", role: .destructive) {
                    model.clearLocalMobilityProfile()
                    learningDataVersion += 1
                }
            }

            Section {
                Toggle("Learn bike routes",
                       isOn: Binding(
                        get: { prefs.bikeRouteLearningEnabled },
                        set: { prefs.bikeRouteLearningEnabled = $0; save() }
                       ))
                Text("Recorded rides: \(model.bikeRouteStore.routes.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Bike routes")
            } footer: {
                Text("When on, Cozy Fox records coarse GPS samples during cycling sessions to learn your habitual bike routes. Samples stay on this device. Low Power Mode disables sampling automatically regardless of this toggle.")
                    .font(.footnote)
            }

            Section("Access routes") {
                Text("Cozy Fox caches Apple Maps walking and biking routes from your frequent locations to nearby transit stops, so chips reflect practical access time rather than straight-line distance. Entries refresh automatically once a day to catch bridge closures and construction reroutes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Cached routes: \(model.walkingStore.entryCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh now") {
                    model.walkingStore.invalidateAll()
                }
                Button("Clear access route cache", role: .destructive) {
                    model.walkingStore.clearAll()
                }
            }

            Section {
                Button("Reset learning", role: .destructive) {
                    showResetLearningConfirmation = true
                }
            } footer: {
                Text("On-device data Cozy Fox keeps to learn your habits. Nothing leaves your phone.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showWorkEntry) {
            WorkAddressEntry()
        }
        .onAppear {
            reloadFromKeychain()
            Task { await model.location.refreshMotion() }
        }
        .confirmationDialog(
            "Reset on-device learning?",
            isPresented: $showResetLearningConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset learning", role: .destructive) {
                model.arrivalBiasStore.clearAll()
                model.walkingStore.clearWalkSpeedEstimate()
                model.walkingStore.clearCycleSpeedEstimate()
                model.bikeRouteStore.clearAll()
                model.suggestionSuppression.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears what Cozy Fox has learned about your trips. New samples will be collected as you use the app.")
        }
    }

    // MARK: - Keychain helpers

    /// Writes to the Keychain, then immediately reads back to confirm what
    /// `APIKeys.read` returns. Surfaces any mismatch as visible text in the UI
    /// so persistence issues are diagnosable end-to-end.
    private func saveAndRoundtrip(_ service: APIKeys.Service, value: String) -> String {
        if value.isEmpty {
            APIKeys.delete(service)
            return "field empty (Keychain entry deleted)"
        }
        let wrote = APIKeys.write(service, value: value)
        let readBack = APIKeys.read(service)
        guard wrote else {
            return "✗ Keychain write FAILED"
        }
        guard let readBack else {
            return "⚠ Wrote, but read-back returned nil"
        }
        if readBack == value {
            return "✓ Saved & read-back matches (\(value.count) chars)"
        } else {
            return "⚠ Read-back returned \(readBack.count) chars, expected \(value.count)"
        }
    }

    private func reloadFromKeychain() {
        let t = APIKeys.read(.trainTracker) ?? ""
        let b = APIKeys.read(.busTracker) ?? ""
        let m = APIKeys.read(.metra) ?? ""
        trainKey = t
        busKey = b
        metraKey = m
        trainSaveStatus = t.isEmpty ? "Keychain empty" : "✓ Loaded \(t.count) chars from Keychain"
        busSaveStatus = b.isEmpty ? "Keychain empty" : "✓ Loaded \(b.count) chars from Keychain"
        metraSaveStatus = m.isEmpty ? "Keychain empty" : "✓ Loaded \(m.count) chars from Keychain"
    }

    @ViewBuilder
    private var visibilitySection: some View {
        Section {
            modeToggle(.trains, title: "Trains", systemImage: "tram.fill")
            modeToggle(.buses, title: "Buses", systemImage: "bus.fill")
            modeToggle(.metra, title: "Metra", systemImage: "train.side.front.car")
            modeToggle(.bikes, title: "Divvy", systemImage: "bicycle")
            modeToggle(.intercampus, title: "Intercampus", systemImage: "bus.fill")

            routeVisibilityHeader(
                title: "L lines",
                selected: visibleTrainLineCount,
                total: LineColor.allCases.count,
                allAction: { setAllTrainLines(visible: true) },
                noneAction: { setAllTrainLines(visible: false) }
            )
            LazyVGrid(columns: visibilityChipColumns, alignment: .leading, spacing: ChicagoSpacing.xs) {
                ForEach(LineColor.allCases, id: \.self) { line in
                    VisibilityRouteChip(
                        isVisible: isTrainLineSelected(line),
                        action: { toggleTrainLine(line) }
                    ) {
                        RouteBadge(line: line, size: .sm)
                    }
                }
            }

            routeVisibilityHeader(
                title: "Bus routes",
                selected: visibleBusRouteCount,
                total: BusStopCatalog.allRoutes.count,
                allAction: { setAllBusRoutes(visible: true) },
                noneAction: { setAllBusRoutes(visible: false) }
            )
            LazyVGrid(columns: visibilityChipColumns, alignment: .leading, spacing: ChicagoSpacing.xs) {
                ForEach(BusStopCatalog.allRoutes, id: \.self) { route in
                    VisibilityRouteChip(
                        isVisible: isBusRouteSelected(route),
                        action: { toggleBusRoute(route) }
                    ) {
                        RouteBadge(bus: route, size: .sm)
                    }
                }
            }

            routeVisibilityHeader(
                title: "Metra lines",
                selected: visibleMetraRouteCount,
                total: MetraStationCatalog.routes.count,
                allAction: { setAllMetraRoutes(visible: true) },
                noneAction: { setAllMetraRoutes(visible: false) }
            )
            LazyVGrid(columns: visibilityChipColumns, alignment: .leading, spacing: ChicagoSpacing.xs) {
                ForEach(MetraStationCatalog.routes, id: \.id) { route in
                    VisibilityRouteChip(
                        isVisible: isMetraRouteSelected(route.id),
                        action: { toggleMetraRoute(route.id) }
                    ) {
                        RouteBadge(metra: route.id, size: .sm)
                    }
                }
            }
        } header: {
            Text("Visible service")
        }
    }

    private var visibilityChipColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 74), spacing: ChicagoSpacing.xs)]
    }

    private var visibleTrainLineCount: Int {
        LineColor.allCases.filter(isTrainLineSelected).count
    }

    private var visibleBusRouteCount: Int {
        BusStopCatalog.allRoutes.filter(isBusRouteSelected).count
    }

    private var visibleMetraRouteCount: Int {
        MetraStationCatalog.routes.map(\.id).filter(isMetraRouteSelected).count
    }

    private func isTrainLineSelected(_ line: LineColor) -> Bool {
        !prefs.hiddenTrainLines.contains(line)
    }

    private func isBusRouteSelected(_ route: String) -> Bool {
        !prefs.hiddenBusRoutes.contains(route)
    }

    private func isMetraRouteSelected(_ routeId: String) -> Bool {
        !prefs.hiddenMetraRoutes.contains(routeId)
    }

    private func modeToggle(
        _ mode: TransitVisibilityMode,
        title: String,
        systemImage: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { modeIsVisible(mode) },
            set: { setMode(mode, visible: $0) }
        )) {
            Label(title, systemImage: systemImage)
                .font(ChicagoTypography.body(.medium, relativeTo: .subheadline))
        }
        .tint(accent(for: mode))
    }

    private func accent(for mode: TransitVisibilityMode) -> Color {
        switch mode {
        case .buses:
            ChicagoPalette.Mode.bus
        case .bikes:
            ChicagoPalette.Mode.divvy
        case .intercampus:
            ChicagoPalette.Mode.intercampus
        case .trains, .metra:
            ChicagoPalette.Gray.dark
        }
    }

    private func routeVisibilityHeader(
        title: String,
        selected: Int,
        total: Int,
        allAction: @escaping () -> Void,
        noneAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: ChicagoSpacing.sm) {
            Text(title)
                .font(ChicagoTypography.body(.bold, relativeTo: .subheadline))
            Text("\(selected)/\(total)")
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(ChicagoPalette.Gray.medium)
            Spacer()
            Button("All", action: allAction)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
            Button("None", action: noneAction)
                .font(ChicagoTypography.body(.medium, relativeTo: .caption))
        }
        .padding(.top, ChicagoSpacing.xs)
    }

    private func modeIsVisible(_ mode: TransitVisibilityMode) -> Bool {
        switch mode {
        case .intercampus:
            prefs.includeIntercampus && prefs.isModeVisible(.intercampus)
        default:
            prefs.isModeVisible(mode)
        }
    }

    private func setMode(_ mode: TransitVisibilityMode, visible: Bool) {
        if visible {
            prefs.hiddenModes.remove(mode)
            if mode == .intercampus {
                prefs.includeIntercampus = true
            }
        } else {
            prefs.hiddenModes.insert(mode)
        }
        save(refresh: true)
    }

    private func toggleTrainLine(_ line: LineColor) {
        if prefs.hiddenTrainLines.contains(line) {
            prefs.hiddenTrainLines.remove(line)
        } else {
            prefs.hiddenTrainLines.insert(line)
        }
        save(refresh: true)
    }

    private func setAllTrainLines(visible: Bool) {
        if visible {
            prefs.hiddenTrainLines.subtract(Set(LineColor.allCases))
        } else {
            prefs.hiddenTrainLines.formUnion(LineColor.allCases)
        }
        save(refresh: true)
    }

    private func toggleBusRoute(_ route: String) {
        if prefs.hiddenBusRoutes.contains(route) {
            prefs.hiddenBusRoutes.remove(route)
        } else {
            prefs.hiddenBusRoutes.insert(route)
        }
        save(refresh: true)
    }

    private func setAllBusRoutes(visible: Bool) {
        if visible {
            prefs.hiddenBusRoutes.subtract(Set(BusStopCatalog.allRoutes))
        } else {
            prefs.hiddenBusRoutes.formUnion(BusStopCatalog.allRoutes)
        }
        save(refresh: true)
    }

    private func toggleMetraRoute(_ routeId: String) {
        if prefs.hiddenMetraRoutes.contains(routeId) {
            prefs.hiddenMetraRoutes.remove(routeId)
        } else {
            prefs.hiddenMetraRoutes.insert(routeId)
        }
        save(refresh: true)
    }

    private func setAllMetraRoutes(visible: Bool) {
        let routeIds = MetraStationCatalog.routes.map(\.id)
        if visible {
            prefs.hiddenMetraRoutes.subtract(Set(routeIds))
        } else {
            prefs.hiddenMetraRoutes.formUnion(routeIds)
        }
        save(refresh: true)
    }

    private func save(refresh: Bool = false) {
        model.preferences.saveRoutePreferences(prefs)
        model.pinRevision += 1
        if refresh {
            Task { await model.refreshIfNeeded(force: true) }
        }
    }

    private func setIntercampusEnabled(_ enabled: Bool) {
        prefs.includeIntercampus = enabled
        if !enabled {
            prefs.pinnedIntercampusDirection = nil
            prefs.pinnedIntercampusStopId = nil
        }
        save()
        model.pinRevision += 1
        Task { await model.refreshIfNeeded(force: true) }
    }

    private func setAutopinEnabled(_ enabled: Bool) {
        prefs.autopinEnabled = enabled
        if !enabled, prefs.pinSource == .automatic {
            prefs.pinnedLine = nil
            prefs.pinnedStationId = nil
            prefs.pinnedTrainDestinations = nil
            prefs.pinnedBusRoute = nil
            prefs.pinnedBusDirection = nil
            prefs.pinnedBusStopId = nil
            prefs.pinnedMetraRoute = nil
            prefs.pinnedMetraStationId = nil
            prefs.pinnedMetraDirectionId = nil
            prefs.pinnedMetraDestination = nil
            prefs.autoPinnedDirection = nil
            prefs.pinSource = .manual
        }
        save()
        model.pinRevision += 1
    }

    // MARK: - API key verification

    @ViewBuilder
    private func statusIcon(for check: APIKeyCheck, hasKey: Bool) -> some View {
        switch check {
        case .untested:
            if hasKey {
                Image(systemName: "key.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Key saved, not yet verified")
            }
        case .ok:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Key accepted by CTA")
        case .badKey:
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Key rejected by CTA")
        case .unreachable:
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityLabel("Couldn't reach CTA")
        }
    }

    @ViewBuilder
    private func statusRow(for check: APIKeyCheck, label: String) -> some View {
        switch check {
        case .untested:
            EmptyView()
        case .ok:
            Label("\(label) accepted", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .badKey(let reason):
            Label("\(label) rejected — \(reason)", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        case .unreachable:
            Label("\(label): couldn't reach transit API (network?)", systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func verifyKeys() async {
        isVerifying = true
        defer { isVerifying = false }
        async let train = APIKeyVerifier.checkTrainKey()
        async let bus = APIKeyVerifier.checkBusKey()
        async let metra = APIKeyVerifier.checkMetraKey()
        let (t, b, m) = await (train, bus, metra)
        trainVerify = t
        busVerify = b
        metraVerify = m
    }
}

// MARK: - API key verifier

enum APIKeyCheck: Equatable, Sendable {
    case untested
    case ok
    case badKey(String)
    case unreachable
}

private struct DepartureTimeBelief {
    let count: Int
    let peakHour: Int?
    let latest: Date?
}

private struct VisibilityRouteChip<Badge: View>: View {
    let isVisible: Bool
    let action: () -> Void
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        Button(action: action) {
            HStack(spacing: ChicagoSpacing.xs) {
                badge()
                    .opacity(isVisible ? 1 : 0.42)
                Spacer(minLength: 0)
                Image(systemName: isVisible ? "checkmark" : "minus")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isVisible ? ChicagoPalette.green : ChicagoPalette.Gray.light)
                    .frame(width: 12)
            }
            .padding(.horizontal, ChicagoSpacing.xs)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .fill(isVisible ? ChicagoPalette.Surface.elevated : ChicagoPalette.Gray.lightest.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                    .strokeBorder(
                        isVisible ? ChicagoPalette.Gray.light.opacity(0.34) : ChicagoPalette.Gray.light.opacity(0.22),
                        lineWidth: ChicagoSpacing.Stroke.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isVisible ? "Visible" : "Hidden")
    }
}

/// Hits each CTA API directly with the keychain-stored key and inspects the
/// response envelope for auth errors (the production clients silently ignore
/// `errCd` / `error` payloads, so we need a separate verification path).
enum APIKeyVerifier {
    static func checkTrainKey() async -> APIKeyCheck {
        guard let key = APIKeys.read(.trainTracker), !key.isEmpty else { return .untested }
        guard
            let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "http://lapi.transitchicago.com/api/1.0/ttarrivals.aspx?key=\(escaped)&mapid=40380&max=1&outputType=JSON")
        else { return .unreachable }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unreachable
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ctatt = json["ctatt"] as? [String: Any]
            else { return .unreachable }
            let errCd = ctatt["errCd"] as? String ?? "0"
            if errCd == "0" { return .ok }
            let name = (ctatt["errNm"] as? String) ?? "CTA error \(errCd)"
            return .badKey(name)
        } catch {
            return .unreachable
        }
    }

    static func checkBusKey() async -> APIKeyCheck {
        guard let key = APIKeys.read(.busTracker), !key.isEmpty else { return .untested }
        guard
            let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://ctabustracker.com/bustime/api/v2/getroutes?key=\(escaped)&format=json")
        else { return .unreachable }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .unreachable
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let body = json["bustime-response"] as? [String: Any]
            else { return .unreachable }
            if let errors = body["error"] as? [[String: Any]], let first = errors.first {
                let msg = (first["msg"] as? String) ?? "Authentication failed"
                return .badKey(msg)
            }
            if body["routes"] != nil { return .ok }
            return .unreachable
        } catch {
            return .unreachable
        }
    }

    static func checkMetraKey() async -> APIKeyCheck {
        guard let key = APIKeys.read(.metra), !key.isEmpty else { return .untested }
        guard let url = URL(string: "https://gtfspublic.metrarr.com/gtfs/public/tripupdates") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if (200..<300).contains(http.statusCode) { return .ok }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .badKey("Metra rejected the bearer token")
            }
            return .unreachable
        } catch {
            return .unreachable
        }
    }
}

// MARK: - Manual work-address entry

private struct WorkAddressEntry: View {
    @Environment(AppViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .region(.chicagoLoop)
    @State private var status: LookupStatus = .idle

    private enum LookupStatus {
        case idle
        case searching
        case found(String)
        case error(String)
    }

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
                } header: {
                    Text("Address")
                } footer: {
                    Text("Enter a street address, neighborhood, or landmark. We'll geocode it with Apple Maps; nothing leaves your device beyond that lookup.")
                        .font(.footnote)
                }

                statusSection

                if let coordinate {
                    Section("Preview") {
                        Map(position: $camera, interactionModes: [.pan, .zoom]) {
                            Marker("Work", coordinate: coordinate).tint(.blue)
                        }
                        .frame(height: 220)
                    }
                }
            }
            .navigationTitle("Work address")
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
                if let existing = model.preferences.loadCommuteAnchors().work {
                    let coord = CLLocationCoordinate2D(latitude: existing.latitude, longitude: existing.longitude)
                    coordinate = coord
                    camera = .camera(MapCamera(centerCoordinate: coord, distance: 1_500))
                }
            }
        }
    }

    private var isSearching: Bool {
        if case .searching = status { return true } else { return false }
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
        case .error(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func lookup() {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        status = .searching
        Task {
            let result = await GeocodeService.lookup(query)
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

    private func save() {
        guard let coord = coordinate else { return }
        var anchors = model.preferences.loadCommuteAnchors()
        anchors.work = .init(latitude: coord.latitude, longitude: coord.longitude, label: "Work")
        model.preferences.saveCommuteAnchors(anchors)
        model.location.updateAnchors(anchors)
        dismiss()
    }
}

// MARK: - Geocoding helper (isolates non-Sendable CoreLocation types)

private struct GeocodeHit: Sendable {
    let coordinate: CLLocationCoordinate2D
    let label: String
}

/// Custom outcome rather than `Result<_, Error>` so the failure path can carry
/// a plain string for the UI without forcing a wrapper error type.
private enum GeocodeOutcome: Sendable {
    case success(GeocodeHit)
    case failure(String)
}

private enum GeocodeService {
    /// Runs geocoding off the main actor and returns only Sendable values so
    /// strict-concurrency stays happy.
    static func lookup(_ query: String) async -> GeocodeOutcome {
        await Task.detached { () -> GeocodeOutcome in
            do {
                let placemarks = try await CLGeocoder().geocodeAddressString(query)
                guard let placemark = placemarks.first, let location = placemark.location else {
                    return .failure("No results.")
                }
                let label = [placemark.name, placemark.locality]
                    .compactMap { $0 }
                    .joined(separator: ", ")
                return .success(GeocodeHit(coordinate: location.coordinate, label: label))
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value
    }
}

private enum ReverseGeocodeService {
    static func lookup(_ location: LastKnownLocation?) async -> String? {
        guard let location else { return nil }
        return await lookup(latitude: location.latitude, longitude: location.longitude)
    }

    static func lookup(_ anchor: CommuteAnchors.Anchor?) async -> String? {
        guard let anchor else { return nil }
        return await lookup(latitude: anchor.latitude, longitude: anchor.longitude)
    }

    private static func lookup(latitude: Double, longitude: Double) async -> String? {
        await Task.detached { () -> String? in
            do {
                let location = CLLocation(latitude: latitude, longitude: longitude)
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                guard let placemark = placemarks.first else { return nil }
                return placemarkSummary(placemark)
            } catch {
                return nil
            }
        }.value
    }

    private static func placemarkSummary(_ placemark: CLPlacemark) -> String {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let locality = [placemark.locality, placemark.administrativeArea]
            .compactMap { $0 }
            .joined(separator: ", ")
        let firstLine = street.isEmpty ? placemark.name : street
        return [firstLine, locality]
            .compactMap { part in
                guard let part, !part.isEmpty else { return nil }
                return part
            }
            .joined(separator: ", ")
    }
}
