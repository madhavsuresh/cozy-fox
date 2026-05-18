import Foundation
import Testing
@testable import TransitModels

@Suite("ServiceAlert filtering")
struct AlertFilterTests {
    private func alert(
        id: String = "a",
        provider: ServiceAlertProvider = .cta,
        lines: [LineColor] = [],
        routes: [String] = []
    ) -> ServiceAlert {
        ServiceAlert(
            id: id,
            headline: "h",
            shortDescription: "d",
            severity: .low,
            provider: provider,
            impactedRoutes: routes,
            impactedLineColors: lines,
            beginsAt: .distantPast,
            endsAt: nil,
            isMajor: false
        )
    }

    @Test func lineOnlyMatch() {
        let alerts = [
            alert(id: "red", lines: [.red]),
            alert(id: "blue", lines: [.blue])
        ]
        let result = alerts.filtered(forLine: .red, busRoute: nil)
        #expect(result.map(\.id) == ["red"])
    }

    @Test func routeOnlyMatch() {
        let alerts = [
            alert(id: "22", routes: ["22"]),
            alert(id: "9", routes: ["9"])
        ]
        let result = alerts.filtered(forLine: nil, busRoute: "22")
        #expect(result.map(\.id) == ["22"])
    }

    @Test func bothNilReturnsEmpty() {
        let alerts = [alert(id: "red", lines: [.red]), alert(id: "22", routes: ["22"])]
        #expect(alerts.filtered(forLine: nil, busRoute: nil).isEmpty)
    }

    @Test func matchingNeitherReturnsEmpty() {
        let alerts = [alert(id: "blue", lines: [.blue], routes: ["9"])]
        #expect(alerts.filtered(forLine: .red, busRoute: "22").isEmpty)
    }

    @Test func lineOrRouteMatchesUnion() {
        let alerts = [
            alert(id: "red", lines: [.red]),
            alert(id: "22", routes: ["22"]),
            alert(id: "noise", lines: [.yellow], routes: ["9"])
        ]
        let result = alerts.filtered(forLine: .red, busRoute: "22")
        #expect(Set(result.map(\.id)) == ["red", "22"])
    }

    @Test func amtrakProviderWideNoticeRequiresAmtrakContext() {
        let alerts = [
            alert(id: "amtrak", provider: .amtrak),
            alert(id: "red", lines: [.red])
        ]

        let ctaOnly = alerts.filtered(
            forLines: [.red],
            busRoutes: [],
            metraRoutes: [],
            amtrakRoutes: []
        )
        #expect(ctaOnly.map(\.id) == ["red"])

        let withAmtrak = alerts.filtered(
            forLines: [],
            busRoutes: [],
            metraRoutes: [],
            amtrakRoutes: ["51"]
        )
        #expect(withAmtrak.map(\.id) == ["amtrak"])
    }

    @Test func amtrakRouteSpecificNoticeMatchesOnlyThatRoute() {
        let alerts = [
            alert(id: "southwest-chief", provider: .amtrak, routes: ["51"]),
            alert(id: "acela", provider: .amtrak, routes: ["40751"])
        ]

        let result = alerts.filtered(forLine: nil, busRoute: nil, amtrakRoute: "51")

        #expect(result.map(\.id) == ["southwest-chief"])
    }
}
