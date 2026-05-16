import Foundation
import Testing
@testable import TransitModels

@Suite("PlannerCoordinate")
struct PlannerCoordinateTests {
    @Test func codableRoundTrip() throws {
        let original = PlannerCoordinate(latitude: 41.882, longitude: -87.627)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlannerCoordinate.self, from: data)
        #expect(decoded == original)
    }

    @Test func hashableEquality() {
        let a = PlannerCoordinate(latitude: 41, longitude: -87)
        let b = PlannerCoordinate(latitude: 41, longitude: -87)
        let c = PlannerCoordinate(latitude: 42, longitude: -87)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
    }
}
