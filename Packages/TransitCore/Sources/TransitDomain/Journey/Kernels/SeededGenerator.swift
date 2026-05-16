import Foundation

/// Tiny linear-congruential `RandomNumberGenerator` for deterministic tests
/// of journey kernels. Numerical Recipes constants — not for cryptographic use.
public struct SeededLCG: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed
    }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Box-Muller transform: returns one standard-normal sample from a
/// uniform `RandomNumberGenerator`. Pair the result with mean/sigma to
/// shift/scale.
public func nextGaussian<G: RandomNumberGenerator>(_ rng: inout G) -> Double {
    let u1raw = Double(rng.next()) / Double(UInt64.max)
    let u1 = max(1e-12, u1raw)
    let u2 = Double(rng.next()) / Double(UInt64.max)
    return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
}
