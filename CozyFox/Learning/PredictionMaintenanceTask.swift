@preconcurrency import BackgroundTasks
import Foundation
import TransitCache
import TransitModels

/// Nightly low-priority BGTask that decays `ArrivalBiasStore` cells with a
/// 30-day half-life so service-pattern changes age out gracefully without
/// erasing the running statistics outright. Long-lived mobility summaries
/// are folded incrementally by `MobilityProfileSummarizer` on every
/// `MobilityProfile.record*` call, so this task only owns the bias-store
/// half of the maintenance pipeline.
enum PredictionMaintenanceTask {
    static let identifier = "net.thoughtbison.cozyfox.learning.maintenance"

    /// Picked so the bias decay window matches roughly one season transition
    /// — long enough that a few outlier days don't wash a stable estimate
    /// away, short enough that a real schedule change is reflected within a
    /// month.
    static let biasHalfLifeDays: Double = 30

    /// Register the BG task handler. Call once at app launch. Mirrors
    /// `RefreshTaskScheduler.register` in shape.
    static func register(arrivalBiasStore: ArrivalBiasStore) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            handle(task: task as! BGProcessingTask, arrivalBiasStore: arrivalBiasStore)
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
        arrivalBiasStore: ArrivalBiasStore
    ) {
        let work = Task { @MainActor in
            await runMaintenance(arrivalBiasStore: arrivalBiasStore, now: .now)
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
    static func runMaintenance(arrivalBiasStore: ArrivalBiasStore, now: Date) async {
        await arrivalBiasStore.hydrateFromDiskIfNeeded()
        arrivalBiasStore.decay(halfLifeDays: biasHalfLifeDays, now: now)
        await arrivalBiasStore.persistNow()
    }
}
