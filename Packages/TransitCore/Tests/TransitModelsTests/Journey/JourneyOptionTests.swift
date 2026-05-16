import Foundation
import Testing
@testable import TransitModels

@Suite("JourneyOption")
struct JourneyOptionTests {
    private func sampleLeg(_ mode: LegMode = .ctaTrain) -> LegCandidate {
        LegCandidate(
            mode: mode,
            displayLabel: "Sample \(mode.rawValue)",
            fromPoint: .anchor(.home),
            toPoint: .anchor(.work)
        )
    }

    @Test func fixedSlotExposesSingleCandidate() {
        let leg = sampleLeg()
        let slot = JourneySlot.fixed(leg)
        #expect(slot.candidates == [leg])
    }

    @Test func exchangeableSlotExposesAllAlternatives() {
        let alts = [sampleLeg(.walk), sampleLeg(.divvyEBike)]
        let slot = JourneySlot.exchangeable(alternatives: alts, policyHint: "lowest p80")
        #expect(slot.candidates == alts)
    }

    @Test func codableRoundTripWithBothSlotKinds() throws {
        let train = sampleLeg(.ctaTrain)
        let walk = sampleLeg(.walk)
        let divvy = sampleLeg(.divvyEBike)
        let option = JourneyOption(
            title: "Red Line + final mile",
            summary: "Red → Belmont → walk or e-Divvy",
            slots: [
                .fixed(train),
                .exchangeable(alternatives: [walk, divvy], policyHint: "lowest p80")
            ],
            tradeoffLabel: "best realistic"
        )
        let data = try JSONEncoder().encode(option)
        let decoded = try JSONDecoder().decode(JourneyOption.self, from: data)
        #expect(decoded == option)
    }
}
