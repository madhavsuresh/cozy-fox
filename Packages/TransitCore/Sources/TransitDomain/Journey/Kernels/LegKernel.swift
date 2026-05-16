import Foundation
import TransitModels

public struct LegOutcome: Sendable, Hashable {
    public let totalDuration: TimeInterval
    public let didFail: Bool
    public let failureReason: String?

    public init(
        totalDuration: TimeInterval,
        didFail: Bool = false,
        failureReason: String? = nil
    ) {
        self.totalDuration = totalDuration
        self.didFail = didFail
        self.failureReason = failureReason
    }
}

public protocol PreparedLegProcess: Sendable {
    func summary() -> TimeDistributionSummary
    func sample<G: RandomNumberGenerator>(startingAt: Date, rng: inout G) -> LegOutcome
}

public protocol LegKernel: Sendable {
    associatedtype Prepared: PreparedLegProcess
    func prepare() async -> Prepared
}
