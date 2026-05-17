import Foundation

/// One observation of a bus vehicle at a single refresh tick — the minimum
/// state we need to compute an along-pattern speed from later observations.
///
/// Phase 3b keeps a sliding window of these in memory on
/// `RefreshCoordinator` (no SwiftData; ~8 entries per pinned vehicle is
/// plenty), so the geometry blender can compute a robust median speed and
/// produce an independent ETA to compare against CTA's `prdtm`.
public struct BusVehicleHistorySample: Codable, Sendable, Hashable {
    public let vehicleId: String
    public let observedAt: Date
    public let patternId: Int?
    public let patternDistanceFeet: Double?

    public init(
        vehicleId: String,
        observedAt: Date,
        patternId: Int?,
        patternDistanceFeet: Double?
    ) {
        self.vehicleId = vehicleId
        self.observedAt = observedAt
        self.patternId = patternId
        self.patternDistanceFeet = patternDistanceFeet
    }
}
