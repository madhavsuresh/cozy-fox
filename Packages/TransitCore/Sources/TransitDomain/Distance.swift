import Foundation

public enum Distance {
    /// Haversine distance in meters between two lat/lon pairs. No CoreLocation
    /// dependency so this is usable from tests and pure modules.
    public static func meters(
        from a: (lat: Double, lon: Double),
        to b: (lat: Double, lon: Double)
    ) -> Double {
        let earthRadius = 6_371_008.8 // meters, mean
        let phi1 = a.lat * .pi / 180
        let phi2 = b.lat * .pi / 180
        let dPhi = (b.lat - a.lat) * .pi / 180
        let dLambda = (b.lon - a.lon) * .pi / 180

        let sinDPhi = sin(dPhi / 2)
        let sinDLambda = sin(dLambda / 2)
        let h = sinDPhi * sinDPhi + cos(phi1) * cos(phi2) * sinDLambda * sinDLambda
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadius * c
    }
}
