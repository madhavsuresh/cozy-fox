import Foundation
import Testing
@testable import TransitDomain

@Suite("River-crossing penalty")
struct RiverPenaltyTests {
    // Canonical reference points used across tests.
    // Streeterville reference point used across tests, just north of the
    // river main branch on the east side of the city.
    private let ontario = (lat: 41.8930, lon: -87.6182)
    private let stateLake = (lat: 41.88574, lon: -87.627835)
    private let washingtonWabash = (lat: 41.88322, lon: -87.626189)
    private let clarkLake = (lat: 41.885737, lon: -87.630886)
    private let merchMart = (lat: 41.888969, lon: -87.633924)
    private let chicagoFranklin = (lat: 41.89681, lon: -87.635924)
    private let sedgwick = (lat: 41.910409, lon: -87.639302)

    @Test func ontarioToStateLakeCrossesMainBranch() {
        #expect(RiverPenalty.crosses(from: ontario, to: stateLake))
        #expect(RiverPenalty.penalty(from: ontario, to: stateLake) == RiverPenalty.crossingMeters)
    }

    @Test func ontarioToWashingtonWabashCrossesMainBranch() {
        #expect(RiverPenalty.crosses(from: ontario, to: washingtonWabash))
    }

    @Test func ontarioToClarkLakeCrossesMainBranch() {
        #expect(RiverPenalty.crosses(from: ontario, to: clarkLake))
    }

    @Test func ontarioToMerchandiseMartDoesNotCross() {
        // Merch Mart's entrance sits ~70m north of the river bank, so the
        // straight line from Ontario stays on the north side.
        #expect(!RiverPenalty.crosses(from: ontario, to: merchMart))
        #expect(RiverPenalty.penalty(from: ontario, to: merchMart) == 0)
    }

    @Test func ontarioToChicagoFranklinDoesNotCross() {
        #expect(!RiverPenalty.crosses(from: ontario, to: chicagoFranklin))
    }

    @Test func ontarioToSedgwickStaysEastOfNorthBranch() {
        // Both points sit east of the north branch; the straight line never
        // reaches the river.
        #expect(!RiverPenalty.crosses(from: ontario, to: sedgwick))
    }

    @Test func loopToRiverNorthCrossesMainBranch() {
        let loop = (lat: 41.8819, lon: -87.6278)
        let riverNorth = (lat: 41.8950, lon: -87.6320)
        #expect(RiverPenalty.crosses(from: loop, to: riverNorth))
    }

    @Test func sedgwickToWickerParkCrossesNorthBranch() {
        // Sedgwick (Brown/Purple, east of north branch) to a Wicker Park
        // location west of north branch — the straight line crosses.
        let wickerPark = (lat: 41.9100, lon: -87.6770)
        #expect(RiverPenalty.crosses(from: sedgwick, to: wickerPark))
    }

    @Test func samePointHasNoPenalty() {
        #expect(RiverPenalty.penalty(from: ontario, to: ontario) == 0)
    }

    @Test func southLoopToChinatownDoesNotCrossUnnecessarily() {
        // Both south of the main branch and east of the south branch:
        // straight line should stay clear of the river.
        let southLoop = (lat: 41.8650, lon: -87.6260)
        let chinatown = (lat: 41.8530, lon: -87.6310)
        #expect(!RiverPenalty.crosses(from: southLoop, to: chinatown))
    }
}
