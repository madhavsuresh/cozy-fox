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
        isApproaching: Bool
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
    }

    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }
}
