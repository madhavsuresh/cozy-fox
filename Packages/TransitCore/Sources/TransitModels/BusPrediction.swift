import Foundation

/// A predicted bus arrival at a stop.
public struct BusPrediction: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let route: String
    public let routeName: String
    public let vehicleId: String
    public let stopId: Int
    public let stopName: String
    public let destinationName: String
    public let directionName: String
    public let generatedAt: Date
    public let arrivalAt: Date
    public let isDelayed: Bool
    public let isApproaching: Bool
    /// CTA Bus Tracker `dyn` (dynamic action) code. 0 / nil = normal
    /// real-time prediction. Non-zero values mark non-standard trips —
    /// the BusTime Developer Guide enumerates them (cancelled, expressed,
    /// invalidated, layover/garage-pullout, etc.) but we deliberately
    /// don't fork on specific codes yet: any non-zero value is treated
    /// as "CTA flagged this as not-quite-normal" and downgrades the
    /// reliability state. See `BusReliabilityScorer` and
    /// `docs/BUS_RELIABILITY.md`.
    public let dynamicActionCode: Int?
    /// True when CTA's `prdctdn` countdown field came back as the literal
    /// string `"DLY"` — their sentinel for "this trip is delayed and we
    /// don't have a confident ETA." Distinct from `isDelayed` (the `dly`
    /// boolean), which CTA sets independently; the two are correlated but
    /// not identical. Drives a soft reliability downgrade.
    public let predictionCountdownIsUncertain: Bool

    public init(
        id: String,
        route: String,
        routeName: String,
        vehicleId: String,
        stopId: Int,
        stopName: String,
        destinationName: String,
        directionName: String,
        generatedAt: Date,
        arrivalAt: Date,
        isDelayed: Bool,
        isApproaching: Bool,
        dynamicActionCode: Int? = nil,
        predictionCountdownIsUncertain: Bool = false
    ) {
        self.id = id
        self.route = route
        self.routeName = routeName
        self.vehicleId = vehicleId
        self.stopId = stopId
        self.stopName = stopName
        self.destinationName = destinationName
        self.directionName = directionName
        self.generatedAt = generatedAt
        self.arrivalAt = arrivalAt
        self.isDelayed = isDelayed
        self.isApproaching = isApproaching
        self.dynamicActionCode = dynamicActionCode
        self.predictionCountdownIsUncertain = predictionCountdownIsUncertain
    }

    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }

    /// True when CTA's `dyn` came back non-zero — i.e. this isn't a
    /// standard real-time prediction. Convenience for callers that
    /// shouldn't care about the specific code.
    public var hasNonStandardDynamicAction: Bool {
        guard let code = dynamicActionCode else { return false }
        return code != 0
    }
}

extension BusPrediction {
    /// Backwards-compatible decoder: older snapshots / caches encoded
    /// without `dynamicActionCode` or `predictionCountdownIsUncertain`
    /// still decode cleanly with those fields defaulting to nil / false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            route: try c.decode(String.self, forKey: .route),
            routeName: try c.decode(String.self, forKey: .routeName),
            vehicleId: try c.decode(String.self, forKey: .vehicleId),
            stopId: try c.decode(Int.self, forKey: .stopId),
            stopName: try c.decode(String.self, forKey: .stopName),
            destinationName: try c.decode(String.self, forKey: .destinationName),
            directionName: try c.decode(String.self, forKey: .directionName),
            generatedAt: try c.decode(Date.self, forKey: .generatedAt),
            arrivalAt: try c.decode(Date.self, forKey: .arrivalAt),
            isDelayed: try c.decode(Bool.self, forKey: .isDelayed),
            isApproaching: try c.decode(Bool.self, forKey: .isApproaching),
            dynamicActionCode: try c.decodeIfPresent(Int.self, forKey: .dynamicActionCode),
            predictionCountdownIsUncertain:
                try c.decodeIfPresent(Bool.self, forKey: .predictionCountdownIsUncertain) ?? false
        )
    }
}
