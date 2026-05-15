import Foundation
import Testing
@testable import TransitModels

@Suite("RouteOption shape and Codable")
struct RouteOptionTests {
    @Test func identityAndLegsSurviveCodable() throws {
        let id = UUID()
        let option = RouteOption(
            id: id,
            label: "Brown Line via Belmont",
            role: .primary,
            legs: [
                RouteOptionLeg(
                    mode: .walking,
                    fromStopID: nil,
                    toStopID: .lStation(40380),
                    approximateDistanceMeters: 320
                ),
                RouteOptionLeg(
                    mode: .transit,
                    transit: TransitLegInfo(
                        rawName: "Brown Line",
                        resolution: .line(.brown)
                    ),
                    fromStopID: .lStation(40380),
                    toStopID: .lStation(41440),
                    approximateDistanceMeters: 6_400
                ),
            ]
        )

        let data = try JSONEncoder().encode(option)
        let round = try JSONDecoder().decode(RouteOption.self, from: data)

        #expect(round == option)
        #expect(round.id == id)
        #expect(round.legs.count == 2)
        #expect(round.legs[0].mode == .walking)
        #expect(round.legs[1].transit?.resolution == .line(.brown))
    }

    @Test func allTransitStopRefCasesRoundTrip() throws {
        let cases: [TransitStopRef] = [
            .lStation(40380),
            .lPlatform(30173),
            .bus(1234),
            .metra("PALATINE"),
            .intercampus("evanston-davis"),
        ]
        for stopRef in cases {
            let data = try JSONEncoder().encode(stopRef)
            let round = try JSONDecoder().decode(TransitStopRef.self, from: data)
            #expect(round == stopRef)
        }
    }

    @Test func allTransitResolutionCasesRoundTrip() throws {
        let cases: [TransitResolution] = [
            .line(.red),
            .line(.brown),
            .bus("22"),
            .metra("UP-N"),
            .unknown("Some commuter rail"),
        ]
        for resolution in cases {
            let data = try JSONEncoder().encode(resolution)
            let round = try JSONDecoder().decode(TransitResolution.self, from: data)
            #expect(round == resolution)
        }
    }

    @Test func roleEnumExposesFourCases() {
        let all = Set(RouteOptionRole.allCases)
        #expect(all == [.primary, .fastRisky, .slowSafe, .fallback])
    }

    @Test func defaultRoleIsPrimary() {
        let option = RouteOption(label: "x", legs: [])
        #expect(option.role == .primary)
    }
}
