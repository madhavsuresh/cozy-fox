import Foundation
import Testing
@testable import TransitModels

@Suite("RoutePortfolio shape and Codable")
struct RoutePortfolioTests {
    @Test func anchorCasesRoundTrip() throws {
        let cases: [PortfolioAnchor] = [
            .home,
            .work,
            .coordinate(latitude: 41.95, longitude: -87.66, label: "Pickup point"),
        ]
        for anchor in cases {
            let data = try JSONEncoder().encode(anchor)
            let round = try JSONDecoder().decode(PortfolioAnchor.self, from: data)
            #expect(round == anchor)
        }
    }

    @Test func portfolioRoundTripPreservesIdentityAndOptions() throws {
        let portfolioID = UUID()
        let optionID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let portfolio = RoutePortfolio(
            id: portfolioID,
            title: "Home from work",
            direction: .toHome,
            origin: .work,
            destination: .home,
            options: [
                RouteOption(
                    id: optionID,
                    label: "Brown via Belmont",
                    role: .primary,
                    legs: [
                        RouteOptionLeg(
                            mode: .transit,
                            transit: TransitLegInfo(
                                rawName: "Brown Line",
                                resolution: .line(.brown)
                            ),
                            fromStopID: .lStation(40380),
                            toStopID: .lStation(41440),
                            approximateDistanceMeters: 6_400
                        )
                    ]
                )
            ],
            createdAt: createdAt
        )

        let data = try JSONEncoder().encode(portfolio)
        let round = try JSONDecoder().decode(RoutePortfolio.self, from: data)

        #expect(round.id == portfolioID)
        #expect(round.title == "Home from work")
        #expect(round.direction == .toHome)
        #expect(round.origin == .work)
        #expect(round.destination == .home)
        #expect(round.options.count == 1)
        #expect(round.options[0].id == optionID)
        #expect(round.options[0].legs[0].transit?.resolution == .line(.brown))
    }

    @Test func lastRecommendedOptionIDDefaultsToNil() {
        let portfolio = RoutePortfolio(
            title: "x",
            direction: .toHome,
            origin: .home,
            destination: .work
        )
        #expect(portfolio.lastRecommendedOptionID == nil)
        #expect(portfolio.lastEvaluatedAt == nil)
        #expect(portfolio.options.isEmpty)
    }
}
