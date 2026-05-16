import Foundation
import TransitModels

public enum DivvyBikeKind: String, Sendable, Hashable, Codable, CaseIterable {
    case classic
    case ebike
}

public protocol DivvyPredictionProviding: Sendable {
    func usableBikeProbability(stationId: String, at: Date, kind: DivvyBikeKind) async -> Double
    func dockOpenProbability(stationId: String, at: Date) async -> Double
    func freeBikeParkingAllowed(near: PlannerCoordinate, at: Date) async -> Bool
    func rideDurationSeconds(fromStationId: String, toStationId: String, at: Date, kind: DivvyBikeKind) async -> Double
    func rideDurationSigmaSeconds(fromStationId: String, toStationId: String, at: Date, kind: DivvyBikeKind) async -> Double
}

public struct DivvyPredictionStub: DivvyPredictionProviding {
    public let usableClassicProbability: Double
    public let usableEbikeProbability: Double
    public let dockProbability: Double
    public let freeParkAllowed: Bool
    public let classicRideMean: TimeInterval
    public let classicRideSigma: TimeInterval
    public let ebikeRideMean: TimeInterval
    public let ebikeRideSigma: TimeInterval

    public init(
        usableClassicProbability: Double = 0.7,
        usableEbikeProbability: Double = 0.5,
        dockProbability: Double = 0.85,
        freeParkAllowed: Bool = false,
        classicRideMean: TimeInterval = 600,
        classicRideSigma: TimeInterval = 90,
        ebikeRideMean: TimeInterval = 420,
        ebikeRideSigma: TimeInterval = 75
    ) {
        self.usableClassicProbability = max(0, min(1, usableClassicProbability))
        self.usableEbikeProbability = max(0, min(1, usableEbikeProbability))
        self.dockProbability = max(0, min(1, dockProbability))
        self.freeParkAllowed = freeParkAllowed
        self.classicRideMean = max(0, classicRideMean)
        self.classicRideSigma = max(0, classicRideSigma)
        self.ebikeRideMean = max(0, ebikeRideMean)
        self.ebikeRideSigma = max(0, ebikeRideSigma)
    }

    public func usableBikeProbability(stationId: String, at: Date, kind: DivvyBikeKind) async -> Double {
        switch kind {
        case .classic: usableClassicProbability
        case .ebike: usableEbikeProbability
        }
    }

    public func dockOpenProbability(stationId: String, at: Date) async -> Double {
        dockProbability
    }

    public func freeBikeParkingAllowed(near: PlannerCoordinate, at: Date) async -> Bool {
        freeParkAllowed
    }

    public func rideDurationSeconds(fromStationId: String, toStationId: String, at: Date, kind: DivvyBikeKind) async -> Double {
        switch kind {
        case .classic: classicRideMean
        case .ebike: ebikeRideMean
        }
    }

    public func rideDurationSigmaSeconds(fromStationId: String, toStationId: String, at: Date, kind: DivvyBikeKind) async -> Double {
        switch kind {
        case .classic: classicRideSigma
        case .ebike: ebikeRideSigma
        }
    }
}
