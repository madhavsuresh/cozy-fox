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
        // Schedule the bundled JSON catalogs for parsing on a background
        // task so the 7 MB Metra + 2 MB bus stop decodes don't stall the
        // first refresh or scroll interaction.
        Catalogs.prewarm()
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
        let arrivalBiasStore = ArrivalBiasStore()
        let bikeRouteStore = BikeRouteStore()
        let refreshCoordinator = RefreshCoordinator(
            store: store,
            preferences: prefs,
            location: location,
            walkingStore: walkingStore,
            arrivalBiasStore: arrivalBiasStore,
            bikeRouteStore: bikeRouteStore
        )
        let model = AppViewModel(
            store: store,
            preferences: prefs,
            location: location,
            refreshCoordinator: refreshCoordinator,
            walkingStore: walkingStore,
            arrivalBiasStore: arrivalBiasStore,
            bikeRouteStore: bikeRouteStore
        )
        _viewModel = State(initialValue: model)
        RefreshTaskScheduler.register(coordinator: refreshCoordinator)
        PredictionMaintenanceTask.register(
            arrivalBiasStore: arrivalBiasStore
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
