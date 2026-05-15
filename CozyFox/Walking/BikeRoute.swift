import Foundation

/// A single recorded cycling session. Pure value type; persisted by
/// `BikeRouteStore`.
///
/// Each `Sample` carries `(lat, lon, timestamp)`. We don't try to fuse
/// these into a polyline at storage time — that's a downstream concern.
/// The sampler captures whatever the OS hands us (typically every 200 m
/// of movement, more sparsely when stationary).
struct BikeRoute: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let samples: [Sample]

    struct Sample: Codable, Sendable, Hashable {
        let latitude: Double
        let longitude: Double
        let recordedAt: Date
    }

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        samples: [Sample]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
    }

    /// Duration of the ride in seconds. Always positive when constructed
    /// through the sampler; the value type doesn't enforce it (tests
    /// might want exotic inputs).
    var durationSeconds: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    /// Number of samples — useful for "did this ride have enough
    /// granularity to be worth keeping" filters that a future
    /// clustering consumer might apply.
    var sampleCount: Int { samples.count }
}
