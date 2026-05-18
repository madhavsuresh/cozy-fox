import Foundation
import Testing
import TransitModels

@Suite("IntercampusArrival")
struct IntercampusArrivalTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func nearStopTrafficEstimateDoesNotBeatFutureStopTime() {
        let scheduled = now.addingTimeInterval(5 * 60)
        let arrival = arrival(at: scheduled)
        let estimate = IntercampusTrafficEstimate(
            generatedAt: now,
            sourceArrivalAt: scheduled,
            scheduledArrivalAt: scheduled,
            arrivalAt: now.addingTimeInterval(15),
            travelTime: 15,
            distanceMeters: 15
        )

        let adjusted = arrival.applyingTrafficEstimate(estimate)

        #expect(adjusted.arrivalAt == scheduled)
        #expect(adjusted.trafficEstimate?.arrivalAt == scheduled)
        #expect(adjusted.trafficEstimate?.scheduleDeltaSeconds == 0)
        #expect(adjusted.timeSource == .traffic)
    }

    @Test func nearStopTrafficEstimateDoesNotBeatFutureScheduleWhenLiveMapIsImmediate() {
        let liveMap = now.addingTimeInterval(15)
        let scheduled = now.addingTimeInterval(5 * 60)
        let arrival = arrival(at: liveMap, scheduledArrivalAt: scheduled)
        let estimate = IntercampusTrafficEstimate(
            generatedAt: now,
            sourceArrivalAt: liveMap,
            scheduledArrivalAt: scheduled,
            arrivalAt: liveMap,
            travelTime: 15,
            distanceMeters: 15
        )

        let adjusted = arrival.applyingTrafficEstimate(estimate)

        #expect(adjusted.arrivalAt == scheduled)
        #expect(adjusted.trafficEstimate?.arrivalAt == scheduled)
        #expect(adjusted.trafficEstimate?.scheduleDeltaSeconds == 0)
    }

    @Test func trafficEstimateCanStillDelayAStopTime() {
        let source = now.addingTimeInterval(5 * 60)
        let delayed = now.addingTimeInterval(8 * 60)
        let arrival = arrival(at: source)
        let estimate = IntercampusTrafficEstimate(
            generatedAt: now,
            sourceArrivalAt: source,
            scheduledArrivalAt: source,
            arrivalAt: delayed,
            travelTime: 8 * 60,
            distanceMeters: 15
        )

        let adjusted = arrival.applyingTrafficEstimate(estimate)

        #expect(adjusted.arrivalAt == delayed)
        #expect(adjusted.trafficEstimate?.arrivalAt == delayed)
        #expect(adjusted.trafficEstimate?.scheduleDeltaSeconds == TimeInterval(3 * 60))
    }

    @Test func trafficEstimateCanImproveDistantStopTime() {
        let source = now.addingTimeInterval(10 * 60)
        let traffic = now.addingTimeInterval(6 * 60)
        let arrival = arrival(at: source)
        let estimate = IntercampusTrafficEstimate(
            generatedAt: now,
            sourceArrivalAt: source,
            scheduledArrivalAt: source,
            arrivalAt: traffic,
            travelTime: 6 * 60,
            distanceMeters: 1_200
        )

        let adjusted = arrival.applyingTrafficEstimate(estimate)

        #expect(adjusted.arrivalAt == traffic)
        #expect(adjusted.trafficEstimate?.arrivalAt == traffic)
        #expect(adjusted.trafficEstimate?.scheduleDeltaSeconds == TimeInterval(-4 * 60))
    }

    private func arrival(at arrivalAt: Date, scheduledArrivalAt: Date? = nil) -> IntercampusArrival {
        IntercampusArrival(
            id: "intercampus-test",
            routeId: "23174203-507c-48fe-811a-5d13fcf7be65",
            direction: .northbound,
            tripId: "trip",
            vehicleId: "35010",
            vehicleLabel: "35010",
            stopId: "6983f6d3-fcd9-4932-b9fb-7120f8c2f999",
            stopName: "Ward",
            destinationName: "Evanston",
            generatedAt: now,
            arrivalAt: arrivalAt,
            scheduledArrivalAt: scheduledArrivalAt ?? arrivalAt,
            delaySeconds: nil,
            isDelayed: false,
            timeSource: .liveMap
        )
    }
}
