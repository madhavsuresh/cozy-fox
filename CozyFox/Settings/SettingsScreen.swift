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
    @State private var currentApproximateAddress: String?
    @State private var homeApproximateAddress: String?
    @State private var workApproximateAddress: String?
    @State private var addressLookupTask: Task<Void, Never>?

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
                        refreshApproximateAddresses()
                    }
                }
            }

            Section {
                Toggle("Include free-floating e-bikes", isOn: Binding(
                    get: { prefs.includeFreeFloatingBikes },
                    set: { prefs.includeFreeFloatingBikes = $0; save() }
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
            } header: {
                Text("Behavior")
            } footer: {
                Text("Auto-pin predicts a commute direction locally from home/work context and coarse time patterns. Manual pins override it for 30 minutes. With \"Always show\" on, the Live Activity stays in the Dynamic Island / Lock Screen and refreshes whenever the app updates.")
                    .font(.footnote)
            }

            autopinBeliefSection

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
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showWorkEntry, onDismiss: {
            reloadPredictionState()
        }) {
            WorkAddressEntry()
        }
        .onAppear {
            reloadPredictionState()
            reloadFromKeychain()
            Task { await model.location.refreshMotion() }
        }
        .onDisappear {
            addressLookupTask?.cancel()
        }
        .onChange(of: model.pinRevision) { _, _ in
            reloadPredictionState()
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

    private func save() {
        model.preferences.saveRoutePreferences(prefs)
    }

    private func setAutopinEnabled(_ enabled: Bool) {
        prefs.autopinEnabled = enabled
        if !enabled, prefs.pinSource == .automatic {
            prefs.pinnedLine = nil
            prefs.pinnedStationId = nil
            prefs.pinnedTrainDestination = nil
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

    // MARK: - Autopin belief

    @ViewBuilder
    private var autopinBeliefSection: some View {
        let profile = model.preferences.loadMobilityProfile()
        let preview = autopinPreview(profile: profile)

        Section {
            beliefRow("Current place", contextBeliefText)
            beliefRow("Approximate current address", currentAddressText)
            beliefRow("Activity", motionBeliefText)
            beliefRow("Home estimate", anchorAddressText(
                anchor: anchors.home,
                resolved: homeApproximateAddress,
                missing: "No home anchor set yet."
            ))
            beliefRow("Work estimate", anchorAddressText(
                anchor: anchors.work,
                resolved: workApproximateAddress,
                missing: "No work address set yet."
            ))
            beliefRow("Typical home departure", homeDepartureBeliefText(profile))
            beliefRow("Typical work departure", workDepartureBeliefText(profile))
            beliefRow("Next autopin decision", predictionDecisionText(preview))
            beliefRow("Transit it would surface", surfacedTransitText(preview))

            if let override = manualOverrideText {
                beliefRow("Manual override", override)
            }
        } header: {
            Text("Autopin belief")
        } footer: {
            Text("These are the local prediction inputs and output. Activity is read from the iPhone motion coprocessor (always-on, near-zero battery). Approximate addresses are reverse-geocoded for display only and are not saved by Cozy Fox.")
                .font(.footnote)
        }
    }

    private func reloadPredictionState() {
        prefs = model.preferences.loadRoutePreferences()
        anchors = model.preferences.loadCommuteAnchors()
        refreshApproximateAddresses()
    }

    private func refreshApproximateAddresses() {
        addressLookupTask?.cancel()
        currentApproximateAddress = nil
        homeApproximateAddress = nil
        workApproximateAddress = nil

        let current = model.location.lastKnown
        let home = anchors.home
        let work = anchors.work

        addressLookupTask = Task { @MainActor in
            async let currentAddress = ReverseGeocodeService.lookup(current)
            async let homeAddress = ReverseGeocodeService.lookup(home)
            async let workAddress = ReverseGeocodeService.lookup(work)
            let resolved = await (currentAddress, homeAddress, workAddress)
            guard !Task.isCancelled else { return }
            currentApproximateAddress = resolved.0
            homeApproximateAddress = resolved.1
            workApproximateAddress = resolved.2
        }
    }

    private func autopinPreview(profile: MobilityProfile) -> CommuteAutopinner.Result {
        CommuteAutopinner().apply(
            preferences: prefs,
            anchors: anchors,
            profile: profile,
            location: model.location.lastKnown,
            context: model.location.context,
            motion: model.location.motion
        )
    }

    private var contextBeliefText: String {
        switch model.location.context {
        case .atHome: "Home"
        case .atWork: "Work"
        case .elsewhere: "Neither home nor work"
        case .unknown: "Unknown"
        }
    }

    private var motionBeliefText: String {
        switch model.location.motion {
        case .stationary: "Still — motion coprocessor sees no movement."
        case .walking: "Walking — likely on the move."
        case .running: "Running."
        case .cycling: "Cycling."
        case .automotive: "In a vehicle."
        case .unknown: "No recent motion sample yet. Allow Motion & Fitness access for sharper autopin timing."
        }
    }

    private var currentAddressText: String {
        guard let location = model.location.lastKnown else {
            return "Waiting for a foreground location."
        }
        return addressText(
            latitude: location.latitude,
            longitude: location.longitude,
            resolved: currentApproximateAddress
        )
    }

    private func anchorAddressText(
        anchor: CommuteAnchors.Anchor?,
        resolved: String?,
        missing: String
    ) -> String {
        guard let anchor else { return missing }
        return addressText(
            latitude: anchor.latitude,
            longitude: anchor.longitude,
            resolved: resolved
        )
    }

    private func addressText(latitude: Double, longitude: Double, resolved: String?) -> String {
        let coordinate = approximateCoordinateText(latitude: latitude, longitude: longitude)
        guard let resolved, !resolved.isEmpty else { return coordinate }
        return "\(resolved) (\(coordinate))"
    }

    private func approximateCoordinateText(latitude: Double, longitude: Double) -> String {
        String(format: "%.3f, %.3f", latitude, longitude)
    }

    private func homeDepartureBeliefText(_ profile: MobilityProfile) -> String {
        let belief = weekdayDepartureBelief(profile, source: .exitedHome, direction: .toWork)
        guard let peakHour = belief.peakHour else {
            return "No home departures observed yet. Until there are 3 samples, weekdays 5–11 AM are treated as likely work-commute time."
        }
        let sampleText = sampleText(count: belief.count)
        let latest = latestSampleText(belief.latest)
        if belief.count < 3 {
            return "Learning from \(sampleText), often around \(hourLabel(peakHour))\(latest); weekdays 5–11 AM remain the fallback."
        }
        return "Weekdays around \(hourLabel(peakHour)) from \(sampleText)\(latest)."
    }

    private func workDepartureBeliefText(_ profile: MobilityProfile) -> String {
        let belief = weekdayDepartureBelief(profile, source: .exitedWork, direction: .toHome)
        guard let peakHour = belief.peakHour else {
            return "No work departures observed yet. When at work, autopin still targets home."
        }
        return "Weekdays around \(hourLabel(peakHour)) from \(sampleText(count: belief.count))\(latestSampleText(belief.latest)); at work, autopin targets home."
    }

    private func weekdayDepartureBelief(
        _ profile: MobilityProfile,
        source: MobilityProfile.Observation.Source,
        direction: CommuteDirection
    ) -> DepartureTimeBelief {
        let departures = profile.observations.filter {
            $0.source == source
                && $0.direction == direction
                && (2...6).contains($0.weekday)
        }
        let byHour = Dictionary(grouping: departures, by: \.hour)
        let peakHour = byHour.sorted {
            if $0.value.count == $1.value.count {
                return $0.key < $1.key
            }
            return $0.value.count > $1.value.count
        }.first?.key
        let latest = departures.map(\.recordedAt).max()
        return DepartureTimeBelief(count: departures.count, peakHour: peakHour, latest: latest)
    }

    private func sampleText(count: Int) -> String {
        "\(count) weekday \(count == 1 ? "sample" : "samples")"
    }

    private func latestSampleText(_ date: Date?) -> String {
        guard let date else { return "" }
        return "; latest \(dateTimeText(date))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "AM" : "PM"
        return "\(hour12) \(suffix)"
    }

    private var manualOverrideText: String? {
        guard let last = prefs.lastManualPinAt else { return nil }
        let overrideSeconds: TimeInterval = 30 * 60
        guard Date().timeIntervalSince(last) < overrideSeconds else { return nil }
        guard Calendar.current.isDate(last, inSameDayAs: Date()) else { return nil }
        return "Manual pins pause autopin until \(timeText(last.addingTimeInterval(overrideSeconds)))."
    }

    private func predictionDecisionText(_ result: CommuteAutopinner.Result) -> String {
        switch result.reason {
        case .disabled:
            return "Auto-pin is off."
        case .manualOverride:
            return manualOverrideText ?? "Paused by a recent manual pin."
        case .missingLocation:
            return "Waiting for a current location."
        case .missingAnchor:
            return "Missing the \(missingAnchorLabel(for: result.direction)) anchor."
        case .notInCommuteWindow:
            return "At home outside the learned work-commute window."
        case .suppressedByMotion:
            return "At home and still — holding the auto-pin until the motion coprocessor sees you moving."
        case .heldDuringTransit:
            return "Holding \(directionText(result.direction).lowercased()) — motion coprocessor reports you're mid-trip."
        case .noRoute:
            return "\(directionText(result.direction)) was predicted, but no local route matched."
        case .unchanged:
            return "Keeps surfacing \(directionText(result.direction).lowercased())."
        case .pinned:
            return "Would surface \(directionText(result.direction).lowercased())."
        case .cleared:
            return "Would clear the current automatic pin."
        }
    }

    private func missingAnchorLabel(for direction: CommuteDirection?) -> String {
        switch direction {
        case .toHome: "home"
        case .toWork: "work"
        case .anytime, nil: "home or work"
        }
    }

    private func directionText(_ direction: CommuteDirection?) -> String {
        direction?.label ?? "No commute direction"
    }

    private func surfacedTransitText(_ result: CommuteAutopinner.Result) -> String {
        let previewPrefs = shouldUsePreviewPins(result.reason) ? result.preferences : prefs
        let summary = pinnedTransitSummary(previewPrefs)
        switch result.reason {
        case .disabled:
            return summary ?? "Auto-pin is off and no route is pinned."
        case .missingLocation, .missingAnchor, .notInCommuteWindow, .suppressedByMotion, .noRoute, .cleared:
            return summary ?? "No transit would be pinned right now."
        case .manualOverride:
            return summary.map { "Manual override: \($0)" } ?? "Manual override is active, with no route pinned."
        case .pinned:
            return summary.map { "Autopin preview: \($0)" } ?? "No transit would be pinned right now."
        case .unchanged, .heldDuringTransit:
            return summary.map { "\(previewPrefs.pinSource.label): \($0)" } ?? "No transit would be pinned right now."
        }
    }

    private func shouldUsePreviewPins(_ reason: CommuteAutopinner.Result.Reason) -> Bool {
        switch reason {
        case .pinned, .unchanged, .cleared, .heldDuringTransit:
            return true
        case .disabled, .manualOverride, .missingLocation, .missingAnchor, .notInCommuteWindow, .suppressedByMotion, .noRoute:
            return false
        }
    }

    private func pinnedTransitSummary(_ preferences: UserRoutePreferences) -> String? {
        var pieces: [String] = []
        if let line = preferences.pinnedLine {
            let station = preferences.pinnedStationId
                .flatMap { id in LStationCatalog.all.first { $0.id == id }?.name }
            if let station {
                pieces.append("\(line.displayName) at \(station)")
            } else {
                pieces.append("\(line.displayName) at nearest station")
            }
        }
        if let route = preferences.pinnedBusRoute {
            if let stopId = preferences.pinnedBusStopId,
               let stop = BusStopCatalog.all.first(where: { $0.route == route && $0.id == stopId })
            {
                pieces.append("Bus #\(route) at \(stop.name)")
            } else if let direction = preferences.pinnedBusDirection {
                pieces.append("Bus #\(route) \(direction)")
            } else {
                pieces.append("Bus #\(route)")
            }
        }
        if let route = preferences.pinnedMetraRoute {
            if let stationId = preferences.pinnedMetraStationId,
               let station = MetraStationCatalog.station(id: stationId)
            {
                pieces.append("Metra \(route) at \(station.name)")
            } else if let destination = preferences.pinnedMetraDestination {
                pieces.append("Metra \(route) to \(destination)")
            } else {
                pieces.append("Metra \(route)")
            }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " + ")
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func beliefRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
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
