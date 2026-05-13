import ActivityKit
import Foundation

/// `ActivityAttributes` shared between the iOS app and the Live Activity
/// extension. Both targets compile this same file so the type identity is
/// preserved across module boundaries (ActivityKit requires that).
///
/// One activity now represents up to TWO legs — a pinned train line + a
/// pinned bus route — so the Dynamic Island can render both side-by-side
/// instead of cycling between two separate activities.
public struct CommuteAttributes: ActivityAttributes, Sendable {

    // MARK: - ContentState (mutable per update)

    public struct ContentState: Codable, Hashable, Sendable {
        public var train: TrainLeg?
        public var bus: BusLeg?

        public init(train: TrainLeg? = nil, bus: BusLeg? = nil) {
            self.train = train
            self.bus = bus
        }
    }

    public struct TrainLeg: Codable, Hashable, Sendable {
        public var routeLabel: String       // "Red Line"
        public var lineColorRaw: String     // LineColor.rawValue
        public var stopName: String         // "Belmont"
        public var destination: String      // "Howard"
        public var nextArrival: Date
        public var followingArrival: Date?
        public var alertHeadline: String?

        public init(
            routeLabel: String,
            lineColorRaw: String,
            stopName: String,
            destination: String,
            nextArrival: Date,
            followingArrival: Date? = nil,
            alertHeadline: String? = nil
        ) {
            self.routeLabel = routeLabel
            self.lineColorRaw = lineColorRaw
            self.stopName = stopName
            self.destination = destination
            self.nextArrival = nextArrival
            self.followingArrival = followingArrival
            self.alertHeadline = alertHeadline
        }
    }

    public struct BusLeg: Codable, Hashable, Sendable {
        public var routeLabel: String       // "Route 22"
        public var stopName: String         // "Clark & Lake"
        public var directionLabel: String   // "Northbound"
        public var destination: String      // "Howard"
        public var nextArrival: Date
        public var followingArrival: Date?
        public var alertHeadline: String?

        public init(
            routeLabel: String,
            stopName: String,
            directionLabel: String,
            destination: String,
            nextArrival: Date,
            followingArrival: Date? = nil,
            alertHeadline: String? = nil
        ) {
            self.routeLabel = routeLabel
            self.stopName = stopName
            self.directionLabel = directionLabel
            self.destination = destination
            self.nextArrival = nextArrival
            self.followingArrival = followingArrival
            self.alertHeadline = alertHeadline
        }
    }

    // MARK: - Identity (immutable per activity instance)

    /// String identifier for what the train leg is tracking. If this changes,
    /// the coordinator ends the current activity and starts a fresh one so
    /// the (immutable) attributes can reflect the new selection. Format is
    /// `"<mapId>-<destination>"` e.g. `"41320-Howard"` — `nil` when no train
    /// is pinned.
    public let trainIdentity: String?

    /// Same idea for bus: `"<route>-<direction>"` e.g. `"22-Northbound"`.
    public let busIdentity: String?

    public init(trainIdentity: String? = nil, busIdentity: String? = nil) {
        self.trainIdentity = trainIdentity
        self.busIdentity = busIdentity
    }
}
