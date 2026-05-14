import SwiftUI
import BackgroundTasks
import ChicagoTheme
import TransitCache
import TransitLocation
import TransitModels
import WidgetKit

@main
struct CozyFoxApp: App {
    @State private var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ChicagoTheme.bootstrap()
        let store: TransitStore
        do {
            store = try TransitStore.live()
        } catch {
            // SwiftData failed to open — fall back to in-memory. Avoid crashing.
            let fallback = try! TransitStore(container: .ephemeral())
            store = fallback
        }
        let prefs = PreferencesStore()
        let anchors = prefs.loadCommuteAnchors()
        let location = LocationCoordinator(preferences: prefs, anchors: anchors)
        let walkingStore = WalkingDistanceStore()
        let mobilitySummaryStore = MobilitySummaryStore()
        let arrivalBiasStore = ArrivalBiasStore()
        let refreshCoordinator = RefreshCoordinator(
            store: store,
            preferences: prefs,
            location: location,
            walkingStore: walkingStore
        )
        let model = AppViewModel(
            store: store,
            preferences: prefs,
            location: location,
            refreshCoordinator: refreshCoordinator,
            walkingStore: walkingStore,
            mobilitySummaryStore: mobilitySummaryStore,
            arrivalBiasStore: arrivalBiasStore
        )
        _viewModel = State(initialValue: model)
        RefreshTaskScheduler.register(coordinator: refreshCoordinator)
        PredictionMaintenanceTask.register(
            mobilitySummaryStore: mobilitySummaryStore,
            arrivalBiasStore: arrivalBiasStore,
            preferences: prefs
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(viewModel)
                // App-level Chicago tint so every button, picker, and
                // toggle inherits Flag Blue — including the Form-based
                // Settings and the Trip Planner.
                .tint(ChicagoPalette.flagBlue)
                .onAppear { Task { await viewModel.bootstrap() } }
                .onOpenURL { viewModel.handleDeepLink($0) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.onScenePhase(newPhase)
        }
    }
}

struct RootView: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.isOnboardingComplete {
            DashboardScreen()
                .sheet(item: $model.activeDetail) { detail in
                    DetailRouter(detail: detail)
                }
        } else {
            OnboardingFlow()
        }
    }
}
