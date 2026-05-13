import Foundation
import MapKit
import TransitModels

/// A single coordinate pair, Sendable so the planner can stay isolated-free.
public struct PlannerCoordinate: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// What kind of motion a leg represents.
public enum TripLegMode: String, Sendable, Hashable {
    case walking
    case transit
    case other
}

/// Cross-referenced CTA identifier for a transit leg.
public enum TransitResolution: Sendable, Hashable {
    /// Matched an L line — e.g. "Blue Line" → `.blue`.
    case line(LineColor)
    /// Matched a CTA bus route in `BusStopCatalog.allRoutes`.
    case bus(String)
    /// Apple returned a transit string we could not map (commuter rail,
    /// out-of-area bus, etc.). Surface the raw text so the UI can still show
    /// something useful.
    case unknown(String)
}

public struct TransitLegInfo: Sendable, Hashable {
    /// Best human-readable name we extracted ("Blue Line", "Route 65", "Metra UP-N").
    public let rawName: String
    public let resolution: TransitResolution

    public init(rawName: String, resolution: TransitResolution) {
        self.rawName = rawName
        self.resolution = resolution
    }
}

public struct TripLeg: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let mode: TripLegMode
    /// Distance covered by this leg, in meters.
    public let distanceMeters: Double
    /// Step instruction text Apple returned, lightly cleaned for display.
    public let instructions: String
    /// Populated only when `mode == .transit`.
    public let transit: TransitLegInfo?

    public init(
        id: UUID = UUID(),
        mode: TripLegMode,
        distanceMeters: Double,
        instructions: String,
        transit: TransitLegInfo?
    ) {
        self.id = id
        self.mode = mode
        self.distanceMeters = distanceMeters
        self.instructions = instructions
        self.transit = transit
    }
}

/// Categorical label describing the tradeoff this plan represents. The
/// screen uses this to render a human-readable header ("Train · Brown Line",
/// "More walking · less time on bus", etc.).
public enum TripPlanFlavor: String, Sendable, Hashable {
    /// Apple Maps route or anything we can't classify ourselves.
    case standard
    /// The fastest L-line option we found.
    case train
    /// Bus pick that minimizes time on the bus (longer walks, shorter ride).
    case busShortestRide
    /// Bus pick that minimizes total walking distance (shorter walks, longer
    /// ride). Only emitted when it's on a different route than the
    /// `busShortestRide` pick — same-route picks would set the same `pinnedBusRoute`.
    case busShortestWalk
}

public struct TripPlan: Sendable, Hashable {
    public let flavor: TripPlanFlavor
    public let summary: String
    public let expectedTravelTime: TimeInterval
    public let totalDistanceMeters: Double
    public let legs: [TripLeg]

    public init(
        flavor: TripPlanFlavor = .standard,
        summary: String,
        expectedTravelTime: TimeInterval,
        totalDistanceMeters: Double,
        legs: [TripLeg]
    ) {
        self.flavor = flavor
        self.summary = summary
        self.expectedTravelTime = expectedTravelTime
        self.totalDistanceMeters = totalDistanceMeters
        self.legs = legs
    }
}

public enum TripPlannerError: Error, Sendable, LocalizedError {
    case noRouteFound

    public var errorDescription: String? {
        switch self {
        case .noRouteFound:
            return "We couldn't find a transit option between those points."
        }
    }
}

/// Tries `MKDirections.calculate(.transit)` first, falling back to a local
/// heuristic over the bundled CTA catalogs when Apple's transit-routing
/// service returns "operation couldn't be completed" — which is the
/// documented behavior in many regions ("Only supported for ETA
/// calculations"). The planner itself is `Sendable` and keeps no state;
/// `plan(from:to:)` is `@MainActor` because the MapKit types we construct
/// along the way are not `Sendable` and would otherwise need awkward
/// isolation gymnastics across the `await` boundary.
public struct TripPlanner: Sendable {
    public let fallback: LocalTransitPlanner

    public init(fallback: LocalTransitPlanner = LocalTransitPlanner()) {
        self.fallback = fallback
    }

    @MainActor
    public func plan(
        from origin: PlannerCoordinate,
        to destination: PlannerCoordinate
    ) async throws -> [TripPlan] {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            placemark: MKPlacemark(coordinate: origin.clLocationCoordinate)
        )
        request.destination = MKMapItem(
            placemark: MKPlacemark(coordinate: destination.clLocationCoordinate)
        )
        request.transportType = .transit
        request.requestsAlternateRoutes = true

        let directions = MKDirections(request: request)
        if let response = try? await directions.calculate(), !response.routes.isEmpty {
            return response.routes.prefix(2).map(Self.decompose(route:))
        }

        // Apple Maps refused the transit query — fall back to a heuristic
        // pick from the bundled CTA catalogs. The local planner returns up to
        // two plans (best train, best bus) so the user can compare.
        let local = fallback.plan(from: origin, to: destination)
        if !local.isEmpty {
            return local
        }

        throw TripPlannerError.noRouteFound
    }

    /// Convert an `MKRoute` into a `TripPlan`. Public so tests in the same
    /// package can exercise the parser without standing up MKDirections.
    @MainActor
    public static func decompose(route: MKRoute) -> TripPlan {
        var legs: [TripLeg] = []
        for step in route.steps {
            // Apple sometimes emits zero-distance "you have arrived" steps;
            // skip those so they don't clutter the list.
            if step.distance <= 0, step.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            let mode: TripLegMode
            switch step.transportType {
            case .transit:
                mode = .transit
            case .walking, .any:
                mode = .walking
            default:
                mode = .other
            }
            let transit: TransitLegInfo?
            if mode == .transit {
                let candidates = [step.instructions, step.notice ?? ""] + route.advisoryNotices
                transit = TransitMatcher.match(in: candidates)
            } else {
                transit = nil
            }
            legs.append(TripLeg(
                mode: mode,
                distanceMeters: step.distance,
                instructions: step.instructions,
                transit: transit
            ))
        }

        return TripPlan(
            summary: route.name,
            expectedTravelTime: route.expectedTravelTime,
            totalDistanceMeters: route.distance,
            legs: legs
        )
    }
}

/// Heuristic regex matcher that cross-references Apple's transit strings
/// against `LineColor` and `BusStopCatalog.allRoutes`. Apple's wording varies
/// ("Blue Line", "CTA Blue Line", "Take Blue Line toward Forest Park",
/// "Route 65", "#65", "Take the 65 Grand bus"), so we try several patterns
/// before falling back to `.unknown(rawText)`.
public enum TransitMatcher {
    public static func match(in candidates: [String]) -> TransitLegInfo {
        let combined = candidates
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let lower = combined.lowercased()

        if let line = matchLine(in: lower) {
            return TransitLegInfo(rawName: line.displayName, resolution: .line(line))
        }

        if let route = matchBusRoute(in: combined) {
            return TransitLegInfo(rawName: "Route \(route)", resolution: .bus(route))
        }

        let fallback = candidates.first(where: { !$0.isEmpty }) ?? "Transit"
        return TransitLegInfo(rawName: fallback, resolution: .unknown(fallback))
    }

    static func matchLine(in lower: String) -> LineColor? {
        // Match the full "Blue Line" phrasing first; this avoids false hits
        // like "Brown" appearing inside an unrelated word.
        for line in LineColor.allCases {
            if lower.contains(line.displayName.lowercased()) {
                return line
            }
        }
        // Fallback: standalone color word adjacent to "line" with surrounding
        // punctuation (e.g. "CTA-Blue/Line"). Cheap regex.
        for line in LineColor.allCases {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: line.rawValue))\\b.{0,4}\\bline\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                return line
            }
        }
        return nil
    }

    static func matchBusRoute(in text: String) -> String? {
        let routes = BusStopCatalog.allRoutes
        guard !routes.isEmpty else { return nil }
        let routeLookup = Dictionary(uniqueKeysWithValues: routes.map { ($0.uppercased(), $0) })

        // Patterns are tried in order. Each must capture group 1 = candidate
        // route token. Tokens are then validated against the catalog so we
        // don't accept "Route 99999" or arbitrary garbage.
        let patterns: [String] = [
            #"(?i)\broute\s+([A-Za-z]?\d{1,3}[A-Za-z]?)\b"#,
            #"(?i)\bbus\s+(?:route\s+)?([A-Za-z]?\d{1,3}[A-Za-z]?)\b"#,
            #"(?i)#([A-Za-z]?\d{1,3}[A-Za-z]?)\b"#,
            #"(?i)\btake\s+(?:the\s+)?(?:cta\s+)?([A-Za-z]?\d{1,3}[A-Za-z]?)\s+bus\b"#,
            #"(?i)\bcta\s+(?:#)?([A-Za-z]?\d{1,3}[A-Za-z]?)\s+bus\b"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
                continue
            }
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let candidate = String(text[r]).uppercased()
            if let exact = routeLookup[candidate] {
                return exact
            }
        }
        return nil
    }
}
