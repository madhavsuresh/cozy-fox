import Foundation

public enum JourneyAnchorKind: String, Sendable, Hashable, Codable, CaseIterable {
    case home
    case work
}

public enum JourneyPoint: Sendable, Hashable, Codable {
    case anchor(JourneyAnchorKind)
    case coordinate(latitude: Double, longitude: Double)
    case stop(systemRef: String, name: String, latitude: Double, longitude: Double)
    case station(systemRef: String, name: String, lineHint: String?)
    case divvyStation(stationId: String, name: String, latitude: Double, longitude: Double)
    case namedPlace(title: String, subtitle: String?, latitude: Double?, longitude: Double?)

    public var displayTitle: String {
        switch self {
        case .anchor(let kind):
            return kind == .home ? "Home" : "Work"
        case .coordinate(let lat, let lon):
            return String(format: "%.4f, %.4f", lat, lon)
        case .stop(_, let name, _, _):
            return name
        case .station(_, let name, _):
            return name
        case .divvyStation(_, let name, _, _):
            return name
        case .namedPlace(let title, _, _, _):
            return title
        }
    }

    public var coordinate: PlannerCoordinate? {
        switch self {
        case .anchor:
            return nil
        case .coordinate(let lat, let lon):
            return PlannerCoordinate(latitude: lat, longitude: lon)
        case .stop(_, _, let lat, let lon):
            return PlannerCoordinate(latitude: lat, longitude: lon)
        case .station:
            return nil
        case .divvyStation(_, _, let lat, let lon):
            return PlannerCoordinate(latitude: lat, longitude: lon)
        case .namedPlace(_, _, let lat, let lon):
            guard let lat, let lon else { return nil }
            return PlannerCoordinate(latitude: lat, longitude: lon)
        }
    }
}
