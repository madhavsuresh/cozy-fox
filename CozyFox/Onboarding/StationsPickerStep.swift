import SwiftUI
import TransitModels

/// Final onboarding step. For v1 we leave concrete station/stop discovery to a
/// post-onboarding "Add a route" flow accessible from Settings; this screen
/// captures the toggle preferences and finishes onboarding so the user can
/// start seeing the dashboard immediately.
struct StationsPickerStep: View {
    let done: () -> Void

    @Environment(AppViewModel.self) private var model
    @State private var includeFreeFloating: Bool = true
    @State private var autoStartLiveActivity: Bool = true

    var body: some View {
        Form {
            Section("Divvy") {
                Toggle("Also consider free-floating e-bikes", isOn: $includeFreeFloating)
                Text("When on, Cozy Fox surfaces the closest e-bike whether it's at a station or parked at the curb.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Commute") {
                Toggle("Start a Live Activity when I leave home/work", isOn: $autoStartLiveActivity)
                Text("Cozy Fox uses an invisible region around home and work to know when you're heading out. It uses zero battery while you're still.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("After finishing setup, open Settings → Routes to add the trains and buses you actually use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Finish setup") {
                    var prefs = model.preferences.loadRoutePreferences()
                    prefs.includeFreeFloatingBikes = includeFreeFloating
                    prefs.autoStartLiveActivity = autoStartLiveActivity
                    model.preferences.saveRoutePreferences(prefs)
                    done()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Almost done")
    }
}
