import Foundation
import Testing
@testable import TransitModels

@Suite("LegWatch")
struct LegWatchTests {
    @Test func priorityOrdersAscending() {
        let sorted = [LegWatchPriority.p4, .p1, .p3, .p0, .p2].sorted()
        #expect(sorted == [.p0, .p1, .p2, .p3, .p4])
    }

    @Test func defaultPolicyMonotonicInIntervalsAcrossPriorities() {
        let policies = LegWatchPriority.allCases.map { LegRefreshPolicy.default(for: $0) }
        for i in 1..<policies.count {
            #expect(policies[i].minIntervalSeconds >= policies[i - 1].minIntervalSeconds)
            #expect(policies[i].maxIntervalSeconds >= policies[i - 1].maxIntervalSeconds)
        }
    }

    @Test func codableRoundTrip() throws {
        let original = LegWatch(
            optionID: UUID(),
            slotIndex: 0,
            role: "currentLeg",
            priority: .p1,
            lastUpdatedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            affectedOptionIDs: [UUID()]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LegWatch.self, from: data)
        #expect(decoded == original)
    }

    @Test func policyClampsMaxBelowMin() {
        let policy = LegRefreshPolicy(minIntervalSeconds: 500, maxIntervalSeconds: 100)
        #expect(policy.maxIntervalSeconds == 500)
    }
}
