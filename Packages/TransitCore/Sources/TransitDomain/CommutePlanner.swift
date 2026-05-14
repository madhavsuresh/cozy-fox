import Foundation
import TransitModels

/// Decides which train/bus preference to surface as the "primary" pick based on
/// the user's current commute context and the time of day.
public struct CommutePlanner: Sendable {
    public let clock: Clock

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    public func primaryTrain(
        from preferences: [TrainPreference],
        context: CommuteContext
    ) -> TrainPreference? {
        select(preferences, direction: preferredDirection(context: context))
    }

    public func primaryBus(
        from preferences: [BusPreference],
        context: CommuteContext
    ) -> BusPreference? {
        select(preferences, direction: preferredDirection(context: context))
    }

    public func primaryMetra(
        from preferences: [MetraPreference],
        context: CommuteContext
    ) -> MetraPreference? {
        select(preferences, direction: preferredDirection(context: context))
    }

    private func select<T>(_ items: [T], direction: CommuteDirection) -> T?
    where T: PreferenceCommute {
        // Prefer items that match the inferred direction. Then anytime. Then any.
        if let match = items.first(where: { $0.direction == direction }) { return match }
        if let any = items.first(where: { $0.direction == .anytime }) { return any }
        return items.first
    }

    /// Combine inferred context with hour-of-day. If context is unknown, fall
    /// back to: before noon → toWork, otherwise → toHome.
    public func preferredDirection(context: CommuteContext) -> CommuteDirection {
        switch context {
        case .atHome: return .toWork
        case .atWork: return .toHome
        case .elsewhere, .unknown:
            let hour = clock.calendar.component(.hour, from: clock.now)
            return hour < 12 ? .toWork : .toHome
        }
    }
}

/// Internal protocol for the generic selector above.
public protocol PreferenceCommute {
    var direction: CommuteDirection { get }
}

extension TrainPreference: PreferenceCommute {}
extension BusPreference: PreferenceCommute {}
extension MetraPreference: PreferenceCommute {}
