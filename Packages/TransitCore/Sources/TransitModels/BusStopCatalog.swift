import Foundation

/// Complete catalog of CTA bus stops paired with the routes that serve them.
/// Loaded once at startup from `Resources/CTABusStops.json` (bundled into the
/// `TransitModels` target). Source dataset is the Chicago Data Portal's
/// "CTA_BusStops" (`qs84-j7wh`), expanded so each (stop × route) pair is its
/// own entry — that's the granularity the CTA Bus Tracker API expects.
///
/// ~14,000 entries across ~10,800 unique physical stops. The resolver
/// returns the nearest few, then the refresh path calls `getpredictions`
/// for each (route, stopId) tuple.
///
/// To refresh: pull updated JSON and replace `Resources/CTABusStops.json`.
public enum BusStopCatalog {
    public static let all: [BusStop] = loadBundled()

    /// Every distinct CTA bus route name in the catalog, naturally sorted
    /// (numeric routes first by number, lettered routes after). Used by the
    /// dashboard's bus-route picker.
    public static let allRoutes: [String] = loadRouteList()

    /// Stops bucketed by route. Lets nearest-stop / corridor resolvers and
    /// the refresh path skip a full 14k-row scan when they only care about
    /// one route.
    public static let byRoute: [String: [BusStop]] = Dictionary(grouping: all, by: \.route)

    /// Returns every stop on `route` (empty if none).
    public static func stops(onRoute route: String) -> [BusStop] {
        byRoute[route] ?? []
    }

    private static func loadBundled() -> [BusStop] {
        guard
            let url = Bundle.module.url(forResource: "CTABusStops", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("CTABusStops.json missing from TransitModels bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([BusStop].self, from: data)
        } catch {
            assertionFailure("Failed to decode CTABusStops.json: \(error)")
            return []
        }
    }

    private struct RouteOnly: Decodable {
        let route: String
    }

    private static func loadRouteList() -> [String] {
        guard
            let url = Bundle.module.url(forResource: "CTABusStops", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let rows = try? JSONDecoder().decode([RouteOnly].self, from: data)
        else {
            return naturallySortedRoutes(Set(all.map(\.route)))
        }
        return naturallySortedRoutes(Set(rows.map(\.route)))
    }

    private static func naturallySortedRoutes(_ routes: Set<String>) -> [String] {
        routes.sorted { lhs, rhs in
            switch (Int(lhs), Int(rhs)) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true   // numeric before lettered
            case (nil, _?):    return false
            case (nil, nil):   return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
    }
}
