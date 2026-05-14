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
        #expect(
            alert.detailURL?.absoluteString
                == "https://www.transitchicago.com/travel-information/service-updates/alert/?AlertId=12345"
        )
    }

    @Test func synthesizesDetailURLWhenAlertURLMissing() async throws {
        let json = """
        {
          "CTAAlerts": {
            "TimeStamp": "20260513 08:00:00",
            "ErrorCode": "0",
            "Alert": [
              {
                "AlertId": "99999",
                "Headline": "Blue Line: Reduced service",
                "SeverityScore": "20",
                "EventStart": "20260512 06:00:00",
                "ImpactedService": {
                  "Service": {
                    "ServiceType": "R",
                    "ServiceId": "Blue",
                    "ServiceName": "Blue Line"
                  }
                }
              }
            ]
          }
        }
        """
        let stub = StubHTTPClient()
        await stub.register(path: "/api/1.0/alerts.aspx", data: Data(json.utf8))
        let client = CTAAlertsClient(http: stub)
        let alerts = try await client.fetchActiveAlerts(forRoutes: [])
        let alert = try #require(alerts.first)
        let url = try #require(alert.detailURL)
        #expect(url.absoluteString.contains("AlertId=99999"))
        #expect(url.host == "www.transitchicago.com")
    }

    @Test func decodesAlertURLWrappedInObject() async throws {
        let json = """
        {
          "CTAAlerts": {
            "TimeStamp": "20260513 08:00:00",
            "ErrorCode": "0",
            "Alert": [
              {
                "AlertId": "77777",
                "Headline": "Brown Line: Track work",
                "SeverityScore": "60",
                "EventStart": "20260512 06:00:00",
                "AlertURL": { "URL": "https://www.transitchicago.com/alert/77777" },
                "ImpactedService": {
                  "Service": {
                    "ServiceType": "R",
                    "ServiceId": "Brn",
                    "ServiceName": "Brown Line"
                  }
                }
              }
            ]
          }
        }
        """
        let stub = StubHTTPClient()
        await stub.register(path: "/api/1.0/alerts.aspx", data: Data(json.utf8))
        let client = CTAAlertsClient(http: stub)
        let alerts = try await client.fetchActiveAlerts(forRoutes: [])
        let alert = try #require(alerts.first)
        #expect(alert.detailURL?.absoluteString == "https://www.transitchicago.com/alert/77777")
    }
}
