import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("TransitMatcher")
struct TransitMatcherTests {
    @Test func matchesLineByFullName() {
        let info = TransitMatcher.match(in: ["Take Blue Line toward Forest Park"])
        #expect(info.resolution == .line(.blue))
    }

    @Test func matchesLineWhenWrappedInBranding() {
        let info = TransitMatcher.match(in: ["CTA Brown Line"])
        #expect(info.resolution == .line(.brown))
    }

    @Test func matchesPurpleExpressAsPurple() {
        // Apple sometimes emits "Purple Line Express" — we still want .purple.
        let info = TransitMatcher.match(in: ["Purple Line Express toward Linden"])
        #expect(info.resolution == .line(.purple))
    }

    @Test func matchesBusRouteByNumber() {
        let info = TransitMatcher.match(in: ["Take Route 22 bus toward Howard"])
        // Only meaningful if "22" appears in the bundled catalog. It does.
        if case .bus(let route) = info.resolution {
            #expect(route == "22")
        } else {
            Issue.record("Expected bus(22), got \(info.resolution)")
        }
    }

    @Test func matchesBusRouteWithHashPrefix() {
        let info = TransitMatcher.match(in: ["Board #8 northbound"])
        if case .bus(let route) = info.resolution {
            #expect(route == "8")
        } else {
            Issue.record("Expected bus(8), got \(info.resolution)")
        }
    }

    @Test func matchesMetraRoute() {
        let info = TransitMatcher.match(in: ["Take Metra UP-N toward Kenosha"])
        if case .metra(let route) = info.resolution {
            #expect(route == "UP-N")
        } else {
            Issue.record("Expected metra(UP-N), got \(info.resolution)")
        }
    }

    @Test func prefersLineOverIncidentalNumber() {
        // The string mentions "65 minutes" — that should NOT match Route 65.
        // The "Blue Line" mention should win.
        let info = TransitMatcher.match(in: ["Blue Line trip is about 65 minutes"])
        #expect(info.resolution == .line(.blue))
    }
}
