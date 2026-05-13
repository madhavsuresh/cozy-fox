@preconcurrency import BackgroundTasks
import Foundation
import WidgetKit

enum RefreshTaskScheduler {
    static let identifier = "net.thoughtbison.cozyfox.refresh"

    static func register(coordinator: RefreshCoordinator) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            handle(task: task as! BGAppRefreshTask, coordinator: coordinator)
        }
        scheduleNext()
    }

    /// Picks the next-fire time based on the time of day: tighter during
    /// commute windows, sparser otherwise, none overnight.
    static func scheduleNext() {
        guard let delay = nextDelaySeconds() else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(delay)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission can fail when too many tasks are pending; safe to
            // ignore and try again on the next foreground.
        }
    }

    private static func nextDelaySeconds() -> TimeInterval? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        let hour = cal.component(.hour, from: Date())
        switch hour {
        case 23, 0, 1, 2, 3, 4, 5:
            return nil // sleep window
        case 6...9, 16...18:
            // Trains run every ~5 min during rush, so we ask for refreshes
            // at the same cadence. iOS rate-limits BGAppRefreshTask, so
            // this is the minimum we request — actual fires happen
            // whenever the system grants the budget.
            return 5 * 60
        default:
            return 20 * 60
        }
    }

    @MainActor
    private static func handle(task: BGAppRefreshTask, coordinator: RefreshCoordinator) {
        let work = Task { @MainActor in
            await coordinator.refreshAll()
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task { @MainActor in
            _ = await work.result
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: !work.isCancelled)
        }
        scheduleNext()
    }
}
