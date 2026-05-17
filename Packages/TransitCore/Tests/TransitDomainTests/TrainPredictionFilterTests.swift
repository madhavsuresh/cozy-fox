import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("TrainPredictionFilter")
struct TrainPredictionFilterTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func arrival(_ id: String) -> Arrival {
        Arrival(
            id: id,
            line: .red,
            runNumber: "r\(id)",
            destinationName: "95th/Dan Ryan",
            stationId: 40380,
            stationName: "Clark/Division",
            stopId: 30074,
            directionCode: "1",
            predictedAt: now.addingTimeInterval(-15),
            arrivalAt: now.addingTimeInterval(300),
            isApproaching: false,
            isDelayed: false,
            isFault: false,
            isScheduled: false
        )
    }

    private static func reliability(
        _ id: String,
        _ state: TrainArrivalReliability.State,
        score: Double = 0.5
    ) -> TrainArrivalReliability {
        TrainArrivalReliability(id: id, state: state, score: score, reasonCodes: [])
    }

    private static func sample() -> (
        arrivals: [Arrival],
        reliabilities: [String: TrainArrivalReliability]
    ) {
        let arrivals = ["h", "m", "l", "u", "x"].map(arrival)
        let rel: [String: TrainArrivalReliability] = [
            "h": reliability("h", .highConfidence,   score: 0.85),
            "m": reliability("m", .mediumConfidence, score: 0.65),
            "l": reliability("l", .lowConfidence,    score: 0.45),
            "u": reliability("u", .unreliable,       score: 0.25),
            "x": reliability("x", .doNotDisplay,     score: 0.05),
        ]
        return (arrivals, rel)
    }

    @Test("Conservative keeps only highConfidence")
    func conservativeKeepsHighOnly() {
        let (arrivals, rel) = Self.sample()
        let kept = TrainPredictionFilter.filter(arrivals, reliabilities: rel, level: .conservative)
        #expect(kept.map(\.id) == ["h"])
    }

    @Test("Balanced keeps high + medium")
    func balancedKeepsHighAndMedium() {
        let (arrivals, rel) = Self.sample()
        let kept = TrainPredictionFilter.filter(arrivals, reliabilities: rel, level: .balanced)
        #expect(kept.map(\.id) == ["h", "m"])
    }

    @Test("Inclusive keeps everything except doNotDisplay")
    func inclusiveKeepsAllExceptDoNotDisplay() {
        let (arrivals, rel) = Self.sample()
        let kept = TrainPredictionFilter.filter(arrivals, reliabilities: rel, level: .inclusive)
        #expect(kept.map(\.id) == ["h", "m", "l", "u"])
    }

    @Test("Show all keeps everything")
    func showAllKeepsEverything() {
        let (arrivals, rel) = Self.sample()
        let kept = TrainPredictionFilter.filter(arrivals, reliabilities: rel, level: .showAll)
        #expect(kept.map(\.id) == ["h", "m", "l", "u", "x"])
    }

    @Test("Unscored arrivals pass through at every level")
    func unscoredPassesThrough() {
        let arrivals = [Self.arrival("orphan")]
        let rel: [String: TrainArrivalReliability] = [:]
        for level in TrainPredictionFilterLevel.allCases {
            let kept = TrainPredictionFilter.filter(arrivals, reliabilities: rel, level: level)
            #expect(kept.count == 1, "unscored row should survive at level \(level)")
        }
    }

    @Test("Default level is inclusive")
    func defaultLevelIsInclusive() {
        #expect(TrainPredictionFilterLevel.default == .inclusive)
    }

    // MARK: - Debug format

    @Test("Debug line format includes eta, state glyph, score, top reasons")
    func debugLineFormat() {
        let arr = Self.arrival("h")
        let rel = TrainArrivalReliability(
            id: "h",
            state: .highConfidence,
            score: 0.81,
            reasonCodes: [.vehicleFresh, .lineMatch, .nextStopMatchesArrival, .predictionFresh]
        )
        let line = TrainReliabilityDebugFormat.line(
            for: arr,
            reliability: rel,
            now: Self.now
        )
        // ETA is 5 minutes (300 s), "H" for highConfidence, 0.81 score,
        // top 3 reasons joined by comma.
        #expect(line == " 5m  H 0.81  VEHICLE_FRESH,LINE_MATCH,NEXT_STOP_MATCHES_ARRIVAL")
    }

    @Test("Debug line falls back to unscored when no reliability is attached")
    func debugLineUnscored() {
        let arr = Self.arrival("orphan")
        let line = TrainReliabilityDebugFormat.line(
            for: arr,
            reliability: nil,
            now: Self.now
        )
        #expect(line == " 5m  unscored")
    }

    @Test("Debug line uses X glyph for doNotDisplay")
    func debugLineCancelled() {
        let arr = Self.arrival("x")
        let rel = Self.reliability("x", .doNotDisplay, score: 0.05)
        let line = TrainReliabilityDebugFormat.line(
            for: arr,
            reliability: rel,
            now: Self.now
        )
        #expect(line.contains("X 0.05"))
    }
}
