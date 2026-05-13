import Foundation

/// A predicted train arrival at a station platform.
public struct Arrival: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let line: LineColor
    public let runNumber: String
    public let destinationName: String
    public let stationId: Int
    public let stationName: String
    public let stopId: Int
    public let directionCode: String
    public let predictedAt: Date
    public let arrivalAt: Date
    public let isApproaching: Bool
    public let isDelayed: Bool
    public let isFault: Bool
    public let isScheduled: Bool

    public init(
        id: String,
        line: LineColor,
        runNumber: String,
        destinationName: String,
        stationId: Int,
        stationName: String,
        stopId: Int,
        directionCode: String,
        predictedAt: Date,
        arrivalAt: Date,
        isApproaching: Bool,
        isDelayed: Bool,
        isFault: Bool,
        isScheduled: Bool
    ) {
        self.id = id
        self.line = line
        self.runNumber = runNumber
        self.destinationName = destinationName
        self.stationId = stationId
        self.stationName = stationName
        self.stopId = stopId
        self.directionCode = directionCode
        self.predictedAt = predictedAt
        self.arrivalAt = arrivalAt
        self.isApproaching = isApproaching
        self.isDelayed = isDelayed
        self.isFault = isFault
        self.isScheduled = isScheduled
    }

    /// Minutes until the train arrives (negative if in the past).
    public func minutesUntilArrival(now: Date = .now) -> Int {
        Int((arrivalAt.timeIntervalSince(now) / 60).rounded())
    }
}
