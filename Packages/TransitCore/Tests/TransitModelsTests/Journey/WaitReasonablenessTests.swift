import Foundation
import Testing
@testable import TransitModels

@Suite("WaitReasonableness")
struct WaitReasonablenessTests {
    @Test func everyCaseHasNonEmptyLabel() {
        for state in WaitReasonableness.allCases {
            #expect(!state.label.isEmpty)
        }
    }

    @Test func toneMappingCoversEveryCase() {
        let mapped: [WaitReasonableness: ArrivalConfidenceMark.Tone] = [
            .goodWait: .strong,
            .acceptableWait: .strong,
            .bunched: .strong,
            .riskyWait: .normal,
            .badGap: .weak,
            .feedUnreliable: .weak,
            .unknown: .weak
        ]
        for state in WaitReasonableness.allCases {
            #expect(state.tone == mapped[state])
        }
    }

    @Test func codableRawValueRoundTrip() throws {
        let data = try JSONEncoder().encode(WaitReasonableness.riskyWait)
        let decoded = try JSONDecoder().decode(WaitReasonableness.self, from: data)
        #expect(decoded == .riskyWait)
    }
}
