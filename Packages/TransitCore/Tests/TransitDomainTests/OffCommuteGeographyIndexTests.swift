import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("OffCommuteGeographyIndex")
struct OffCommuteGeographyIndexTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func routeObservation(
        recordedAt: Date = now,
        direction: CommuteDirection,
        originLat: Double? = nil,
        originLon: Double? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil
    ) -> MobilityProfile.RouteObservation {
        let origin = (originLat == nil || originLon == nil) ? nil :
            MobilityProfile.RouteLocation(latitude: originLat!, longitude: originLon!, label: nil)
        let destination = (destLat == nil || destLon == nil) ? nil :
            MobilityProfile.RouteLocation(latitude: destLat!, longitude: destLon!, label: nil)
        return MobilityProfile.RouteObservation(
            recordedAt: recordedAt,
            direction: direction,
            context: .atHome,
            line: nil,
            stationId: nil,
            busRoute: nil,
            busDirection: nil,
            origin: origin,
            destination: destination,
            weekday: 2, hour: 8
        )
    }

    // MARK: - Cell quantization

    @Test func cellRoundsConsistently() {
        let a = OffCommuteGeographyIndex.Cell.from(latitude: 41.965, longitude: -87.690)
        let b = OffCommuteGeographyIndex.Cell.from(latitude: 41.967, longitude: -87.688)
        // Both should land in the same cell (within ~500 m).
        #expect(a == b)
    }

    @Test func cellsDifferAcrossDistance() {
        let close = OffCommuteGeographyIndex.Cell.from(latitude: 41.965, longitude: -87.690)
        let far = OffCommuteGeographyIndex.Cell.from(latitude: 41.998, longitude: -87.661)
        #expect(close != far)
    }

    // MARK: - Build

    @Test func emptyObservationsBuildEmpty() {
        let index = OffCommuteGeographyIndex.build(
            from: [],
            currentCommute: .toWork,
            now: Self.now
        )
        #expect(index.cells.isEmpty)
    }

    @Test func skipsCommuteDirectionObservations() {
        // Observation is a .toWork commute — should not feed the
        // index when the suggester is also for .toWork.
        let obs = routeObservation(
            direction: .toWork,
            originLat: 41.965, originLon: -87.690,
            destLat: 41.882, destLon: -87.620
        )
        let index = OffCommuteGeographyIndex.build(
            from: [obs],
            currentCommute: .toWork,
            now: Self.now
        )
        #expect(index.cells.isEmpty)
    }

    @Test func keepsNonCommuteObservations() {
        // Same observation, different direction — feeds the index.
        let obs = routeObservation(
            direction: .toHome,
            originLat: 41.965, originLon: -87.690,
            destLat: 41.882, destLon: -87.620
        )
        let index = OffCommuteGeographyIndex.build(
            from: [obs],
            currentCommute: .toWork,
            now: Self.now
        )
        #expect(index.cells.count == 2)
    }

    @Test func skipsOldObservations() {
        let oldObs = routeObservation(
            recordedAt: Self.now.addingTimeInterval(-100 * 86_400),
            direction: .toHome,
            destLat: 41.965, destLon: -87.690
        )
        let index = OffCommuteGeographyIndex.build(
            from: [oldObs],
            currentCommute: .toWork,
            withinDays: 90,
            now: Self.now
        )
        #expect(index.cells.isEmpty)
    }

    // MARK: - Delight scoring

    @Test func delightScoreZeroWhenIndexEmpty() {
        let empty = OffCommuteGeographyIndex(cells: [])
        let score = empty.delightScore(forPolyline: [
            (lat: 41.9, lon: -87.65), (lat: 41.91, lon: -87.66)
        ])
        #expect(score == 0)
    }

    @Test func delightScoreZeroWhenPolylineTooShort() {
        let index = OffCommuteGeographyIndex(cells: [
            OffCommuteGeographyIndex.Cell.from(latitude: 41.9, longitude: -87.65)
        ])
        let score = index.delightScore(forPolyline: [(lat: 41.9, lon: -87.65)])
        #expect(score == 0)
    }

    @Test func delightScoreFractional() {
        // 4 polyline cells, 2 of which are in the index → 0.5.
        let knownCell1 = OffCommuteGeographyIndex.Cell.from(latitude: 41.9, longitude: -87.65)
        let knownCell2 = OffCommuteGeographyIndex.Cell.from(latitude: 41.95, longitude: -87.65)
        let index = OffCommuteGeographyIndex(cells: [knownCell1, knownCell2])
        // 4 distinct cells in the polyline; mid is 41.9 + 41.95 + two
        // others far away.
        let score = index.delightScore(forPolyline: [
            (lat: 41.90, lon: -87.65),  // known
            (lat: 41.95, lon: -87.65),  // known
            (lat: 42.05, lon: -87.65),  // unknown
            (lat: 42.10, lon: -87.65)   // unknown
        ])
        #expect(score == 0.5)
    }

    @Test func delightScoreOneWhenPolylineFullyKnown() {
        let cell = OffCommuteGeographyIndex.Cell.from(latitude: 41.9, longitude: -87.65)
        let index = OffCommuteGeographyIndex(cells: [cell])
        // Two waypoints chosen to both land in the same cell (the
        // bucketing rounds DOWN, so we keep both points strictly
        // above the cell's lower bound).
        let score = index.delightScore(forPolyline: [
            (lat: 41.9001, lon: -87.6499),
            (lat: 41.9020, lon: -87.6480)
        ])
        #expect(score == 1.0)
    }
}
