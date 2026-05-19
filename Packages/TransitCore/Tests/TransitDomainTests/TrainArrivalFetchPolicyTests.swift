import Testing
@testable import TransitDomain

@Suite("TrainArrivalFetchPolicy")
struct TrainArrivalFetchPolicyTests {
    @Test func singleLineStationGetsFloor() {
        // e.g. 95th/Dan Ryan (red only): 1 line × 2 dir = 2 pairs.
        #expect(TrainArrivalFetchPolicy.maxArrivals(servedLineCount: 1) == 12)
    }

    @Test func belmontGetsFloor() {
        // Belmont (red/brown/purple): 3 × 2 = 6 pairs. 12 keeps the
        // "2 per pair" target the old hardcoded value was sized for.
        #expect(TrainArrivalFetchPolicy.maxArrivals(servedLineCount: 3) == 12)
    }

    @Test func clarkLakeScalesUp() {
        // Clark/Lake (blue + 5 elevated): 6 × 2 = 12 pairs. Needs 24 to
        // keep the Blue Line subway from being crowded out by the loop.
        #expect(TrainArrivalFetchPolicy.maxArrivals(servedLineCount: 6) == 24)
    }
}
