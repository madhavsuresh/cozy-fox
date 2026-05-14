import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("CTA Alerts decoder")
struct CTAAlertsClientTests {
    @Test func decodesAlertsAndSeverity() async throws {
        let stub = StubHTTPClient()
        await stub.register(
            path: "/api/1.0/alerts.aspx",
            data: Fixture.load("cta_alerts")
        )
        let client = CTAAlertsClient(http: stub)
        let alerts = try await client.fetchActiveAlerts(forRoutes: ["Red"])

        #expect(alerts.count == 1)
        let alert = try #require(alerts.first)
        #expect(alert.headline.contains("Wilson"))
        #expect(alert.severity == .medium, "severity 30 should map to medium")
        #expect(alert.impactedRoutes == ["Red"])
        #expect(alert.impactedLineColors == [.red])
    }

    @Test func detailsURLPointsAtAlertsHub() {
        // Every "Details" link in the app goes to the same CTA service-alerts
        // hub, since per-alert detail pages from the API are no longer rendered.
        #expect(ServiceAlert.detailsURL.absoluteString == "https://www.transitchicago.com/alerts/")
    }
}
