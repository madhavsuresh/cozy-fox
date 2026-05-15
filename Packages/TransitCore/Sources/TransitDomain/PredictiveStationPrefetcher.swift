import Foundation
import TransitModels

/// Phase 6 consumer: when `NextContextPredictor` says the user is very
/// likely heading to a known anchor (home or work) from their current
/// state, this resolves the set of nearby `LStation`s whose
/// MapKit walking distances are worth pre-warming. The actual
/// MapKit fetch is the caller's job — this helper is pure so it can
/// be unit-tested without spinning up the resolver.
///
/// Trigger conditions:
/// - The trained predictor returns a top-1 prediction with
///   `probability >= probabilityThreshold` (default 0.6).
/// - The predicted next context is `.atWork` or `.atHome`.
/// - The corresponding anchor is set in `CommuteAnchors`.
///
/// When any of those fail, returns `nil` — the caller does nothing.
public struct PredictiveStationPrefetcher: Sendable {
    private let stationResolver: NearestStationResolver

    /// Search radius (meters) for nearby stations around the predicted
    /// destination anchor. 800 m ≈ a comfortable 10-min walk; large
    /// enough to cover stations the user could plausibly arrive at,
    /// small enough that we're not warming the entire downtown.
    public let radiusMeters: Double

    /// Cap on how many stations to surface for warming. The MapKit
    /// directions API has a rate limiter; warming dozens of stations
    /// for every refresh would burn the budget.
    public let stationLimit: Int

    public init(
        stationResolver: NearestStationResolver = NearestStationResolver(),
        radiusMeters: Double = 800,
        stationLimit: Int = 5
    ) {
        self.stationResolver = stationResolver
        self.radiusMeters = radiusMeters
        self.stationLimit = stationLimit
    }

    public struct Plan: Sendable, Hashable {
        public let origin: Origin
        public let stations: [LStation]

        public struct Origin: Sendable, Hashable {
            public let latitude: Double
            public let longitude: Double
        }

        public init(origin: Origin, stations: [LStation]) {
            self.origin = origin
            self.stations = stations
        }
    }

    /// Returns a prefetch plan when the predictor is confident enough,
    /// else `nil`. Pure — no I/O.
    public func plan(
        profile: MobilityProfile,
        currentContext: CommuteContext,
        anchors: CommuteAnchors,
        now: Date = .now,
        catalog: [LStation] = LStationCatalog.all,
        calendar: Calendar = .current,
        probabilityThreshold: Double = 0.6,
        minSamples: Int = 5
    ) -> Plan? {
        let predictor = NextContextPredictor.train(from: profile.observations)
        let weekday = calendar.component(.weekday, from: now)
        let hour = calendar.component(.hour, from: now)
        let hourOfWeek = HourOfWeek.index(weekday: weekday, hour: hour)

        let predictions = predictor.predict(
            currentContext: currentContext,
            hourOfWeek: hourOfWeek,
            topK: 1,
            minSamples: minSamples
        )
        guard let top = predictions.first, top.probability >= probabilityThreshold else {
            return nil
        }

        let targetAnchor: CommuteAnchors.Anchor?
        switch top.context {
        case .atWork: targetAnchor = anchors.work
        case .atHome: targetAnchor = anchors.home
        case .elsewhere, .unknown: targetAnchor = nil
        }
        guard let anchor = targetAnchor else { return nil }

        let coord = (lat: anchor.latitude, lon: anchor.longitude)
        let nearby = stationResolver.all(within: radiusMeters, of: coord, catalog: catalog)
        let stations = Array(nearby.prefix(stationLimit).map(\.station))
        guard !stations.isEmpty else { return nil }

        return Plan(
            origin: Plan.Origin(latitude: coord.lat, longitude: coord.lon),
            stations: stations
        )
    }
}
