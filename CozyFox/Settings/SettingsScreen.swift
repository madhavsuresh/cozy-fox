import SwiftUI
import MapKit
import TransitModels

struct SettingsScreen: View {
    @Environment(AppViewModel.self) private var model
    @State private var prefs: UserRoutePreferences = .empty
    @State private var anchors: CommuteAnchors = .empty
    @State private var trainKey: String = ""
    @State private var busKey: String = ""
    @State private var showWorkEntry: Bool = false
    @State private var trainVerify: APIKeyCheck = .untested
    @State private var busVerify: APIKeyCheck = .untested
    @State private var isVerifying: Bool = false
    @State private var trainSaveStatus: String = "—"
    @State private var busSaveStatus: String = "—"
    @State private var learningDataVersion: Int = 0

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

                Button("Reload from Keychain") {
                    reloadFromKeychain()
                }

                Button {
                    Task { await verifyKeys() }
                } label: {
                    HStack {
                        if isVerifying { ProgressView().scaleEffect(0.8) }
                        Text(isVerifying ? "Verifying…" : "Verify keys against CTA")
                    }
                }
                .disabled(isVerifying || (trainKey.isEmpty && busKey.isEmpty))
            } header: {
                Text("API keys")
            } footer: {
                Text("Keys auto-save to the iOS Keychain on every keystroke; the status line below each field shows the round-trip read-back. Tap Verify to confirm each key is accepted by the CTA API.")
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
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showWorkEntry, onDismiss: {
            anchors = model.preferences.loadCommuteAnchors()
        }) {
            WorkAddressEntry()
        }
        .onAppear {
            prefs = model.preferences.loadRoutePreferences()
            anchors = model.preferences.loadCommuteAnchors()
            reloadFromKeychain()
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
        trainKey = t
        busKey = b
        trainSaveStatus = t.isEmpty ? "Keychain empty" : "✓ Loaded \(t.count) chars from Keychain"
        busSaveStatus = b.isEmpty ? "Keychain empty" : "✓ Loaded \(b.count) chars from Keychain"
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
            Label("\(label) accepted by CTA", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .badKey(let reason):
            Label("\(label) rejected — \(reason)", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        case .unreachable:
            Label("\(label): couldn't reach CTA (network?)", systemImage: "wifi.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func verifyKeys() async {
        isVerifying = true
        defer { isVerifying = false }
        async let train = APIKeyVerifier.checkTrainKey()
        async let bus = APIKeyVerifier.checkBusKey()
        let (t, b) = await (train, bus)
        trainVerify = t
        busVerify = b
    }
}

// MARK: - API key verifier

enum APIKeyCheck: Equatable, Sendable {
    case untested
    case ok
    case badKey(String)
    case unreachable
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
