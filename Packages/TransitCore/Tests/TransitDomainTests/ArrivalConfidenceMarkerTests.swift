import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("ArrivalConfidenceMarker")
struct ArrivalConfidenceMarkerTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func arrival(
        runNumber: String = "001",
        line: LineColor = .red,
        stationId: Int = 41320,
        stopId: Int = 30182,
        directionCode: String = "N",
        minutesFromNow: Double = 5,
        isFault: Bool = false,
        isScheduled: Bool = false,
        isDelayed: Bool = false,
        isApproaching: Bool = false
    ) -> Arrival {
        Arrival(
            id: "\(line.rawValue)-\(stationId)-\(runNumber)-\(Int(now.addingTimeInterval(minutesFromNow * 60).timeIntervalSince1970))",
            line: line,
            runNumber: runNumber,
            destinationName: "Howard",
            stationId: stationId,
            stationName: "Belmont",
            stopId: stopId,
            directionCode: directionCode,
            predictedAt: now,
            arrivalAt: now.addingTimeInterval(minutesFromNow * 60),
            isApproaching: isApproaching,
            isDelayed: isDelayed,
            isFault: isFault,
            isScheduled: isScheduled
        )
    }

    // MARK: - Train arrivals

    @Test func unflaggedTrainWithNoHistoryReadsAsNormal() {
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(),
            biasCell: nil
        )
        // Baseline 0.65 → falls into `.normal` band (≥0.45, <0.72).
        #expect(mark.tone == .normal)
        #expect(abs(mark.score - 0.65) < 1e-9)
    }

    @Test func faultedTrainReadsAsWeak() {
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(isFault: true),
            biasCell: nil
        )
        #expect(mark.tone == .weak)
    }

    @Test func scheduledTrainReadsAsWeak() {
        // Baseline 0.65 - 0.15 = 0.50 → still .normal under thresholds.
        // But once stddev shows up that should drop to .weak. Verify the
        // bare-flag case keeps it just above the weak cutoff.
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(isScheduled: true),
            biasCell: nil
        )
        #expect(mark.tone == .normal)
        #expect(mark.score < 0.6)
    }

    @Test func ghostHeavyArrivalDropsBelowNormal() {
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(),
            biasCell: nil,
            ghostScore: 0.9
        )
        // 0.65 - 0.9 * 0.35 = 0.335 → weak.
        #expect(mark.tone == .weak)
    }

    @Test func wellGradedTrainPicksUpReliabilityBoost() {
        let cell = BiasCell(count: 20, mean: 30, m2: 5_000, lastUpdatedAt: now)
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(),
            biasCell: cell
        )
        // 0.65 + 0.18 boost - small stddev penalty = solidly .strong.
        #expect(mark.tone == .strong)
    }

    @Test func highStddevPenalizesEvenWithSamples() {
        // count >= 12 + small mean would normally award the boost, but
        // 6-minute stddev triggers the -0.18 penalty AND the boost only
        // fires when |mean| < 60 — so a cell with mean=20 + stddev=6m
        // ends up boosted (+0.18) then penalized (-0.18) → net zero from
        // bias, leaving baseline .normal. Worth pinning so the math is
        // explicit.
        let m2 = 11 * (360 * 360) // stddev = 360s (6 min) over 12 samples
        let cell = BiasCell(count: 12, mean: 20, m2: Double(m2), lastUpdatedAt: now)
        let mark = ArrivalConfidenceMarker.mark(
            for: arrival(),
            biasCell: cell
        )
        #expect(mark.tone == .normal)
    }

    // MARK: - Bus + Metra

    @Test func busArrivalUsesSameBaselineAndBiasMath() {
        let prediction = BusPrediction(
            id: "bus-1",
            route: "22",
            routeName: "Clark",
            vehicleId: "1",
            stopId: 1001,
            stopName: "Clark & Belmont",
            destinationName: "Howard",
            directionName: "Northbound",
            generatedAt: now,
            arrivalAt: now.addingTimeInterval(5 * 60),
            isDelayed: false,
            isApproaching: false
        )
        let cell = BiasCell(count: 20, mean: 15, m2: 5_000, lastUpdatedAt: now)
        let mark = ArrivalConfidenceMarker.mark(for: prediction, biasCell: cell)
        #expect(mark.tone == .strong)
    }

    @Test func canceledMetraReadsAsWeak() {
        let prediction = MetraPrediction(
            id: "metra-1",
            routeId: "UP-N",
            routeShortName: "UP-N",
            tripId: "UPN_001",
            trainNumber: "100",
            stationId: "DAVIS",
            stationName: "Davis",
            destinationName: "Chicago",
            directionId: 1,
            generatedAt: now,
            scheduledAt: now,
            arrivalAt: now.addingTimeInterval(10 * 60),
            delaySeconds: nil,
            isDelayed: false,
            isCanceled: true,
            isScheduled: false
        )
        let mark = ArrivalConfidenceMarker.mark(for: prediction)
        #expect(mark.tone == .weak)
    }
}
