import Foundation
import Testing
@testable import TransitAPI
import TransitModels

@Suite("Amtrak client")
struct AmtrakClientTests {
    @Test func liveUpdatesRemainEmptyUntilOfficialDirectSourceExists() async throws {
        let client = AmtrakClient(http: StubHTTPClient())

        let updates = try await client.fetchLiveUpdates()

        #expect(updates.isEmpty)
    }

    @Test func parsesServiceNoticesFromOfficialNoticePageHtml() async throws {
        let stub = StubHTTPClient()
        let html = """
        <html>
          <body>
            <section class="service-alert">
              <h3>Southwest Chief service modified</h3>
              <p>Amtrak Southwest Chief Train 4 is modified today because of a service disruption.</p>
            </section>
            <section class="notice">
              <h3>Station notice</h3>
              <p>Passengers should allow extra time at major stations during holiday travel periods.</p>
            </section>
          </body>
        </html>
        """
        await stub.register(path: "/service-alerts-and-notices", data: Data(html.utf8))
        let client = AmtrakClient(http: stub)

        let notices = try await client.fetchServiceNotices()

        #expect(notices.count == 2)
        let southwestChief = try #require(notices.first { $0.headline == "Southwest Chief service modified" })
        #expect(southwestChief.provider == .amtrak)
        #expect(southwestChief.sourceLabel == "Notice")
        #expect(southwestChief.severity == .medium)
        #expect(southwestChief.impactedRoutes == ["51"])
        #expect(southwestChief.detailURL == ServiceAlert.amtrakDetailsURL)

        let providerWide = try #require(notices.first { $0.headline == "Station notice" })
        #expect(providerWide.provider == .amtrak)
        #expect(providerWide.impactedRoutes.isEmpty)
    }
}
