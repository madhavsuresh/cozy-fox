import Foundation
import Testing
import TransitModels

@Suite("IntercampusCatalog")
struct IntercampusCatalogTests {
    @Test func loadsRoutesAndStopsByDirection() {
        let northbound = IntercampusCatalog.route(for: .northbound)
        let southbound = IntercampusCatalog.route(for: .southbound)

        #expect(northbound?.id == "23174203-507c-48fe-811a-5d13fcf7be65")
        #expect(southbound?.id == "ebee9228-c993-4279-b7ce-8fca0a46ca65")
        #expect(IntercampusCatalog.stops(for: .northbound).contains { $0.name == "Ward" })
        #expect(IntercampusCatalog.stops(for: .southbound).contains { $0.name == "Ryan Field" })
    }

    @Test func sharedStopsServeBothDirections() throws {
        let ward = try #require(IntercampusCatalog.stop(id: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999"))
        let ryanField = try #require(IntercampusCatalog.stop(id: "60e7b447-b29d-4812-bf93-7a77a1d5ae5b"))

        #expect(ward.servedDirections.contains(.northbound))
        #expect(ward.servedDirections.contains(.southbound))
        #expect(ryanField.servedDirections.contains(.northbound))
        #expect(ryanField.servedDirections.contains(.southbound))
    }

    @Test func resolvesTripRoutesAndStaticSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 14,
            hour: 10,
            minute: 38
        ))!

        #expect(
            IntercampusCatalog.routeId(forTrip: "4afda0c4-b03b-4499-85f0-7137d34d8f24")
                == "ebee9228-c993-4279-b7ce-8fca0a46ca65"
        )

        let arrivals = IntercampusCatalog.scheduledArrivals(
            stopIds: ["b3f50cbe-621f-4664-934a-fe48d4901250"],
            after: now,
            generatedAt: now
        )

        #expect(arrivals.count >= 2)
        #expect(arrivals.first?.direction == .southbound)
        #expect(arrivals.first?.arrivalAt ?? now > now)
        #expect(arrivals.first?.scheduledArrivalAt == arrivals.first?.arrivalAt)
        #expect(arrivals.first?.timeSource == .schedule)
    }

    @Test func resolvesScheduledTravelTimeBetweenIntercampusStops() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 14,
            hour: 8,
            minute: 25
        ))!

        let travelSeconds = try #require(IntercampusCatalog.scheduledTravelSeconds(
            direction: .northbound,
            from: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
            to: "afedecae-1527-498a-94d7-ab1949be7cb6",
            after: now
        ))

        #expect(travelSeconds > 10 * 60)
        #expect(travelSeconds < 60 * 60)
    }
}
