import SwiftUI
import TransitAPI

struct APIKeysStep: View {
    let next: () -> Void

    @State private var trainKey: String = ""
    @State private var busKey: String = ""
    @State private var trainStatus: ValidationStatus = .untested
    @State private var busStatus: ValidationStatus = .untested
    @State private var isValidating = false

    var body: some View {
        Form {
            Section("CTA Train Tracker key") {
                TextField("paste key", text: $trainKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link(
                    "Get a train tracker key",
                    destination: URL(string: "https://www.transitchicago.com/developers/traintrackerapply/")!
                )
                statusLabel(trainStatus)
            }
            Section("CTA Bus Tracker key") {
                TextField("paste key", text: $busKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Link(
                    "Get a bus tracker key",
                    destination: URL(string: "https://www.transitchicago.com/developers/bustracker/")!
                )
                statusLabel(busStatus)
            }
            Section {
                Button(action: validateAndContinue) {
                    HStack {
                        if isValidating { ProgressView() }
                        Text(isValidating ? "Checking…" : "Validate & continue")
                    }
                }
                .disabled(trainKey.isEmpty || busKey.isEmpty || isValidating)
            }
            Section {
                Button("Skip for now — I'll add them in Settings", action: next)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("API keys")
    }

    private func statusLabel(_ status: ValidationStatus) -> some View {
        switch status {
        case .untested: return AnyView(EmptyView())
        case .checking: return AnyView(Label("Checking…", systemImage: "ellipsis").foregroundStyle(.secondary))
        case .ok: return AnyView(Label("Key works", systemImage: "checkmark.seal.fill").foregroundStyle(.green))
        case .failed(let m): return AnyView(Label(m, systemImage: "xmark.seal.fill").foregroundStyle(.red))
        }
    }

    private func validateAndContinue() {
        Task {
            isValidating = true
            defer { isValidating = false }
            APIKeys.write(.trainTracker, value: trainKey.trimmingCharacters(in: .whitespacesAndNewlines))
            APIKeys.write(.busTracker, value: busKey.trimmingCharacters(in: .whitespacesAndNewlines))

            // Cheap probes: hit a known endpoint with the key.
            trainStatus = .checking
            busStatus = .checking
            let http = LiveHTTPClient(session: LiveHTTPClient.makeSharedSession())
            let train = CTATrainClient(http: http) { trainKey }
            let bus = CTABusClient(http: http) { busKey }
            do {
                _ = try await train.fetchArrivals(mapId: 40380, max: 1) // Clark/Division
                trainStatus = .ok
            } catch {
                trainStatus = .failed("Train: \(String(describing: error))")
            }
            do {
                _ = try await bus.fetchPredictions(route: "22", stopId: 1066, top: 1)
                busStatus = .ok
            } catch {
                busStatus = .failed("Bus: \(String(describing: error))")
            }
            if case .ok = trainStatus, case .ok = busStatus { next() }
        }
    }
}

private enum ValidationStatus {
    case untested
    case checking
    case ok
    case failed(String)
}
