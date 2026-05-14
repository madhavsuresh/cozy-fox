@preconcurrency import BackgroundTasks
import Foundation
import TransitCache
import TransitModels

/// Nightly low-priority BGTask that:
///   - Hydrates both learning stores from disk if they haven't been yet.
///   - Folds observations older than 14 days out of the persisted
///     `MobilityProfile` into `MobilitySummaryStore`'s rolling weeklies.
///   - Decays `ArrivalBiasStore` cells with a 30-day half-life so service
///     pattern changes can age out without erasing the cells outright.
///   - Persists both stores, then reschedules itself.
///
/// Phase 0 does nothing else with the results — no notifications, no UI
/// surfaces. The task exists so later phases can plug in without needing to
/// re-bootstrap the maintenance pipeline.
enum PredictionMaintenanceTask {
    static let identifier = "net.thoughtbison.cozyfox.learning.maintenance"

    /// Picked so the bias decay window matches roughly one season transition
    /// — long enough that a few outlier days don't wash a stable estimate
    /// away, short enough that a real schedule change is reflected within a
    /// month.
    static let biasHalfLifeDays: Double = 30

    /// Register the BG task handler. Call once at app launch. Mirrors
    /// `RefreshTaskScheduler.register` in shape.
    static func register(
        mobilitySummaryStore: MobilitySummaryStore,
        arrivalBiasStore: ArrivalBiasStore,
        preferences: PreferencesStore
    ) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            handle(
                task: task as! BGProcessingTask,
                mobilitySummaryStore: mobilitySummaryStore,
                arrivalBiasStore: arrivalBiasStore,
                preferences: preferences
            )
        }
        scheduleNext()
    }

    /// Ask iOS to schedule the next nightly fire. We request "no earlier
    /// than 24h from now" — iOS may run it later if storage/battery isn't
    /// favorable, which is fine for a maintenance pass.
    static func scheduleNext() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission can fail when too many tasks are pending or in
            // simulator builds where BGTaskScheduler is unavailable. Safe to
            // ignore — the next foreground will try again.
        }
    }

    @MainActor
    private static func handle(
        task: BGProcessingTask,
        mobilitySummaryStore: MobilitySummaryStore,
        arrivalBiasStore: ArrivalBiasStore,
        preferences: PreferencesStore
    ) {
        let work = Task { @MainActor in
            await runMaintenance(
                mobilitySummaryStore: mobilitySummaryStore,
                arrivalBiasStore: arrivalBiasStore,
                preferences: preferences,
                now: .now
            )
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task { @MainActor in
            _ = await work.result
            task.setTaskCompleted(success: !work.isCancelled)
        }
        scheduleNext()
    }

    /// The actual maintenance body, split out so tests can drive it directly
    /// without spinning up `BGTaskScheduler`.
    @MainActor
    static func runMaintenance(
        mobilitySummaryStore: MobilitySummaryStore,
        arrivalBiasStore: ArrivalBiasStore,
        preferences: PreferencesStore,
        now: Date
    ) async {
        await mobilitySummaryStore.hydrateFromDiskIfNeeded()
        await arrivalBiasStore.hydrateFromDiskIfNeeded()
        let profile = preferences.loadMobilityProfile()
        let result = mobilitySummaryStore.fold(profile: profile, now: now)
        // Only re-persist the source profile if rows were actually folded
        // out, to avoid an empty rewrite cycle.
        if result.foldedObservationCount + result.foldedRouteObservationCount > 0 {
            preferences.saveMobilityProfile(result.mutatedProfile)
        }
        arrivalBiasStore.decay(halfLifeDays: biasHalfLifeDays, now: now)
        await mobilitySummaryStore.persistNow()
        await arrivalBiasStore.persistNow()
    }
}
