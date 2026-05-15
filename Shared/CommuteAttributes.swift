import ActivityKit
import Foundation
import TransitModels

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
        public var metra: MetraLeg?

        public init(train: TrainLeg? = nil, bus: BusLeg? = nil, metra: MetraLeg? = nil) {
            self.train = train
            self.bus = bus
            self.metra = metra
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
        /// Up to ~6 upcoming arrivals (including `nextArrival`), used to
        /// drive the headway dot-strip on the Live Activity.
        public var upcomingArrivals: [Date]
        /// Nonverbal per-arrival confidence used to vary dot weight /
        /// opacity on the Live Activity. Empty for activities started
        /// before this field existed; the renderer treats absent marks
        /// as `.normal`.
        public var confidenceMarks: [ArrivalConfidenceMark]

        public init(
            routeLabel: String,
            lineColorRaw: String,
            stopName: String,
            destination: String,
            nextArrival: Date,
            followingArrival: Date? = nil,
            alertHeadline: String? = nil,
            upcomingArrivals: [Date] = [],
            confidenceMarks: [ArrivalConfidenceMark] = []
        ) {
            self.routeLabel = routeLabel
            self.lineColorRaw = lineColorRaw
            self.stopName = stopName
            self.destination = destination
            self.nextArrival = nextArrival
            self.followingArrival = followingArrival
            self.alertHeadline = alertHeadline
            self.upcomingArrivals = upcomingArrivals
            self.confidenceMarks = confidenceMarks
        }

        /// Decode tolerates an absent `upcomingArrivals` from older state
        /// (e.g., an activity that was started by the previous app version
        /// and is still alive across an upgrade). Falls back to the two
        /// scalar arrival fields.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            routeLabel = try c.decode(String.self, forKey: .routeLabel)
            lineColorRaw = try c.decode(String.self, forKey: .lineColorRaw)
            stopName = try c.decode(String.self, forKey: .stopName)
            destination = try c.decode(String.self, forKey: .destination)
            nextArrival = try c.decode(Date.self, forKey: .nextArrival)
            followingArrival = try c.decodeIfPresent(Date.self, forKey: .followingArrival)
            alertHeadline = try c.decodeIfPresent(String.self, forKey: .alertHeadline)
            upcomingArrivals = (try? c.decode([Date].self, forKey: .upcomingArrivals))
                ?? [nextArrival, followingArrival].compactMap { $0 }
            confidenceMarks = (try? c.decode([ArrivalConfidenceMark].self, forKey: .confidenceMarks)) ?? []
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
        /// Up to ~6 upcoming arrivals (including `nextArrival`), used to
        /// drive the headway dot-strip on the Live Activity.
        public var upcomingArrivals: [Date]
        /// Nonverbal per-arrival confidence; see `TrainLeg`.
        public var confidenceMarks: [ArrivalConfidenceMark]

        public init(
            routeLabel: String,
            stopName: String,
            directionLabel: String,
            destination: String,
            nextArrival: Date,
            followingArrival: Date? = nil,
            alertHeadline: String? = nil,
            upcomingArrivals: [Date] = [],
            confidenceMarks: [ArrivalConfidenceMark] = []
        ) {
            self.routeLabel = routeLabel
            self.stopName = stopName
            self.directionLabel = directionLabel
            self.destination = destination
            self.nextArrival = nextArrival
            self.followingArrival = followingArrival
            self.alertHeadline = alertHeadline
            self.upcomingArrivals = upcomingArrivals
            self.confidenceMarks = confidenceMarks
        }

        /// Same backwards-compat decoder as `TrainLeg`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            routeLabel = try c.decode(String.self, forKey: .routeLabel)
            stopName = try c.decode(String.self, forKey: .stopName)
            directionLabel = try c.decode(String.self, forKey: .directionLabel)
            destination = try c.decode(String.self, forKey: .destination)
            nextArrival = try c.decode(Date.self, forKey: .nextArrival)
            followingArrival = try c.decodeIfPresent(Date.self, forKey: .followingArrival)
            alertHeadline = try c.decodeIfPresent(String.self, forKey: .alertHeadline)
            upcomingArrivals = (try? c.decode([Date].self, forKey: .upcomingArrivals))
                ?? [nextArrival, followingArrival].compactMap { $0 }
            confidenceMarks = (try? c.decode([ArrivalConfidenceMark].self, forKey: .confidenceMarks)) ?? []
        }
    }

    public struct MetraLeg: Codable, Hashable, Sendable {
        public var routeLabel: String
        public var routeId: String
        public var stopName: String
        public var destination: String
        public var nextArrival: Date
        public var followingArrival: Date?
        public var alertHeadline: String?
        public var upcomingArrivals: [Date]
        /// Nonverbal per-arrival confidence; see `TrainLeg`.
        public var confidenceMarks: [ArrivalConfidenceMark]

        public init(
            routeLabel: String,
            routeId: String,
            stopName: String,
            destination: String,
            nextArrival: Date,
            followingArrival: Date? = nil,
            alertHeadline: String? = nil,
            upcomingArrivals: [Date] = [],
            confidenceMarks: [ArrivalConfidenceMark] = []
        ) {
            self.routeLabel = routeLabel
            self.routeId = routeId
            self.stopName = stopName
            self.destination = destination
            self.nextArrival = nextArrival
            self.followingArrival = followingArrival
            self.alertHeadline = alertHeadline
            self.upcomingArrivals = upcomingArrivals
            self.confidenceMarks = confidenceMarks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            routeLabel = try c.decode(String.self, forKey: .routeLabel)
            routeId = try c.decode(String.self, forKey: .routeId)
            stopName = try c.decode(String.self, forKey: .stopName)
            destination = try c.decode(String.self, forKey: .destination)
            nextArrival = try c.decode(Date.self, forKey: .nextArrival)
            followingArrival = try c.decodeIfPresent(Date.self, forKey: .followingArrival)
            alertHeadline = try c.decodeIfPresent(String.self, forKey: .alertHeadline)
            upcomingArrivals = (try? c.decode([Date].self, forKey: .upcomingArrivals))
                ?? [nextArrival, followingArrival].compactMap { $0 }
            confidenceMarks = (try? c.decode([ArrivalConfidenceMark].self, forKey: .confidenceMarks)) ?? []
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
    public let metraIdentity: String?

    public init(trainIdentity: String? = nil, busIdentity: String? = nil, metraIdentity: String? = nil) {
        self.trainIdentity = trainIdentity
        self.busIdentity = busIdentity
        self.metraIdentity = metraIdentity
    }
}
