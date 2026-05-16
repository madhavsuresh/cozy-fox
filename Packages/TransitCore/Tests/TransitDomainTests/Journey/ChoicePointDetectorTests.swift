import Foundation
import Testing
@testable import TransitDomain
@testable import TransitModels

@Suite("ChoicePointDetector")
struct ChoicePointDetectorTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func walk(at lat: Double, lon: Double, label: String = "walk") -> LegCandidate {
        LegCandidate(
            mode: .walk,
            displayLabel: label,
            fromPoint: .coordinate(latitude: lat, longitude: lon),
            toPoint: .coordinate(latitude: lat, longitude: lon)
        )
    }

    @Test func fixedSlotsProduceNoChoicePoints() {
        let detector = ChoicePointDetector()
        let option = JourneyOption(
            title: "fixed only",
            summary: "",
            slots: [.fixed(walk(at: 41.9, lon: -87.65))]
        )
        #expect(detector.detect(in: option).isEmpty)
    }

    @Test func exchangeableSlotProducesOneChoicePoint() {
        let detector = ChoicePointDetector()
        let walkOption = walk(at: 41.89, lon: -87.62, label: "walk")
        let bikeOption = LegCandidate(
            mode: .divvyEBike,
            displayLabel: "e-Divvy",
            fromPoint: .coordinate(latitude: 41.89, longitude: -87.62),
            toPoint: .coordinate(latitude: 41.90, longitude: -87.61)
        )
        let option = JourneyOption(
            title: "trip",
            summary: "",
            slots: [.exchangeable(alternatives: [walkOption, bikeOption], policyHint: "lowest p80")]
        )
        let points = detector.detect(in: option)
        #expect(points.count == 1)
        #expect(points.first?.title == "walk or e-Divvy")
        #expect(points.first?.recommendationReason == "lowest p80")
        #expect(points.first?.candidateIDs.count == 2)
    }

    @Test func userNearChoicePointIncreasesConfidence() {
        let detector = ChoicePointDetector(proximityRadiusMeters: 500)
        let walkOption = walk(at: 41.89, lon: -87.62, label: "walk")
        let option = JourneyOption(
            title: "trip",
            summary: "",
            slots: [.exchangeable(alternatives: [walkOption], policyHint: nil)]
        )
        let near = detector.detect(in: option, userPosition: PlannerCoordinate(latitude: 41.89, longitude: -87.62)).first
        let far = detector.detect(in: option, userPosition: PlannerCoordinate(latitude: 42.5, longitude: -87.62)).first
        #expect((near?.confidence ?? 0) > (far?.confidence ?? 0))
    }
}
