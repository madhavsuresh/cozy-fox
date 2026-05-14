import Foundation
import Testing
@testable import TransitModels

@Suite("WeeklySummary encoding and LongTermProfile fold semantics")
struct WeeklySummaryTests {
    @Test func weeklySummaryRoundTripsThroughJSON() throws {
        let weekStart = Date(timeIntervalSinceReferenceDate: 770_000_000)
        let anchor = AnchorID.lStation(stationId: 40380)
        let corridor = CorridorSummary(
            origin: .home,
            destination: anchor,
            frequency: 3.0,
            dominantMode: .train
        )
        let summary = WeeklySummary(
            weekStart: weekStart,
            hourlyAnchorHistogram: [
                HourOfWeek.index(weekday: 2, hour: 8): [anchor: 2.0, .home: 1.0]
            ],
            hourlyModeProbabilities: [
                HourOfWeek.index(weekday: 2, hour: 8): ModeWeights(train: 2)
            ],
            topCorridors: [corridor],
            motionDistribution: [.walking: 0.4, .stationary: 0.5, .automotive: 0.1],
            autoencoderReconstructionMean: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        let decoded = try decoder.decode(WeeklySummary.self, from: data)

        #expect(decoded.weekStart == weekStart)
        #expect(decoded.hourlyAnchorHistogram[HourOfWeek.index(weekday: 2, hour: 8)]?[anchor] == 2.0)
        #expect(decoded.topCorridors.first?.origin == .home)
        #expect(decoded.topCorridors.first?.destination == anchor)
        #expect(decoded.motionDistribution[.walking] == 0.4)
        #expect(decoded.autoencoderReconstructionMean == nil)
    }

    @Test func anchorIDEnumerationsEncode() throws {
        let cases: [AnchorID] = [
            .home,
            .work,
            .lStation(stationId: 1),
            .busStop(route: "22", stopId: 4321),
            .metraStation(stationId: "OH-2"),
            .bucketed(latCell: 16752, lonCell: -35080)
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in cases {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(AnchorID.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test func bucketedAnchorMatchesRouteLocationBucketing() {
        // 0.0025° resolution: 41.880 / 0.0025 = 16752; -87.700 / 0.0025 = -35080.
        let a = AnchorID.bucketed(latitude: 41.880, longitude: -87.700)
        #expect(a == .bucketed(latCell: 16752, lonCell: -35080))
    }

    @Test func emptyFoldCopiesNewWeekIntoLongTerm() {
        var profile = LongTermProfile.empty
        let week = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            hourlyAnchorHistogram: [0: [.home: 1.0]],
            hourlyModeProbabilities: [0: ModeWeights(train: 1)],
            topCorridors: [],
            motionDistribution: [.stationary: 1.0]
        )
        profile.fold(week, alpha: 0.3)
        // (1-0.3)*0 + 0.3*1 = 0.3 in the smoothed value.
        #expect(abs((profile.hourlyAnchorHistogram[0]?[.home] ?? 0) - 0.3) < 1e-9)
        #expect(abs((profile.hourlyModeProbabilities[0]?.train ?? 0) - 0.3) < 1e-9)
        #expect(abs((profile.motionDistribution[.stationary] ?? 0) - 0.3) < 1e-9)
        #expect(profile.weekStart == week.weekStart)
    }

    @Test func ewmaFoldGivesExpectedScalar() {
        var profile = LongTermProfile.empty
        let w1 = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            hourlyModeProbabilities: [10: ModeWeights(train: 1)],
            motionDistribution: [.walking: 1.0]
        )
        let w2 = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_604_800),
            hourlyModeProbabilities: [10: ModeWeights(train: 0)],
            motionDistribution: [.walking: 0.0]
        )
        let alpha = 0.3
        profile.fold(w1, alpha: alpha)
        // After w1: train weight = 0.3, walking = 0.3.
        profile.fold(w2, alpha: alpha)
        // After w2: train weight = 0.3 * 0.7 + 0 * 0.3 = 0.21.
        let train = profile.hourlyModeProbabilities[10]?.train ?? 0
        #expect(abs(train - 0.21) < 1e-9)
        let walking = profile.motionDistribution[.walking] ?? 0
        #expect(abs(walking - 0.21) < 1e-9)
    }

    @Test func foldCapsCorridorListAndMergesByPair() {
        var profile = LongTermProfile.empty
        // Build a week with > maxCorridors so we can verify capping.
        let week = WeeklySummary(
            weekStart: Date(timeIntervalSinceReferenceDate: 770_000_000),
            topCorridors: (0..<12).map { i in
                CorridorSummary(
                    origin: .home,
                    destination: .lStation(stationId: i),
                    frequency: Double(i + 1),
                    dominantMode: .train
                )
            }
        )
        profile.fold(week, alpha: 1.0) // alpha=1 to skip smoothing math
        #expect(profile.topCorridors.count == WeeklySummary.maxCorridors)
        // Highest-frequency corridor must survive.
        #expect(profile.topCorridors.first?.destination == .lStation(stationId: 11))
    }

    @Test func modeWeightsNormalize() {
        let w = ModeWeights(train: 3, bus: 1, metra: 0, bike: 0, walk: 1)
        let n = w.normalized()
        #expect(abs(n.train - 0.6) < 1e-9)
        #expect(abs(n.bus - 0.2) < 1e-9)
        #expect(abs(n.walk - 0.2) < 1e-9)
        // Total should be 1.
        #expect(abs(n.total - 1.0) < 1e-9)
        // Normalizing the zero vector returns the zero vector.
        let zero = ModeWeights.zero.normalized()
        #expect(zero.total == 0)
    }

    @Test func reconstructionMeanFoldsOnlyWhenProvided() {
        var profile = LongTermProfile.empty
        var w = WeeklySummary(weekStart: Date())
        profile.fold(w, alpha: 0.5)
        #expect(profile.autoencoderReconstructionMean == nil)
        w.autoencoderReconstructionMean = 1.0
        profile.fold(w, alpha: 0.5)
        // First non-nil sample seeds the long-term value as-is.
        #expect(profile.autoencoderReconstructionMean == 1.0)
        // Subsequent nil should not erase it.
        w.autoencoderReconstructionMean = nil
        profile.fold(w, alpha: 0.5)
        #expect(profile.autoencoderReconstructionMean == 1.0)
        // Subsequent non-nil applies EWMA.
        w.autoencoderReconstructionMean = 0.0
        profile.fold(w, alpha: 0.5)
        #expect(abs(profile.autoencoderReconstructionMean! - 0.5) < 1e-9)
    }
}
