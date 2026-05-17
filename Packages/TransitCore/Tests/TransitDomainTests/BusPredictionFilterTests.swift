import Foundation
import Testing
import TransitModels
@testable import TransitDomain

@Suite("BusPredictionFilter")
struct BusPredictionFilterTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func prediction(_ id: String) -> BusPrediction {
        BusPrediction(
            id: id,
            route: "65",
            routeName: "65 Grand",
            vehicleId: "v\(id)",
            stopId: 456,
            stopName: "Grand & McClurg",
            destinationName: "Grand/Nordica",
            directionName: "Westbound",
            generatedAt: now.addingTimeInterval(-15),
            arrivalAt: now.addingTimeInterval(300),
            isDelayed: false,
            isApproaching: false
        )
    }

    private static func reliability(
        _ id: String,
        _ state: BusArrivalReliability.State,
        score: Double = 0.5
    ) -> BusArrivalReliability {
        BusArrivalReliability(id: id, state: state, score: score, reasonCodes: [])
    }

    private static func sample() -> (
        predictions: [BusPrediction],
        reliabilities: [String: BusArrivalReliability]
    ) {
        let preds = ["h", "m", "l", "u", "x"].map(prediction)
        let rel: [String: BusArrivalReliability] = [
            "h": reliability("h", .highConfidence,   score: 0.85),
            "m": reliability("m", .mediumConfidence, score: 0.65),
            "l": reliability("l", .lowConfidence,    score: 0.45),
            "u": reliability("u", .unreliable,       score: 0.25),
            "x": reliability("x", .doNotDisplay,     score: 0.05),
        ]
        return (preds, rel)
    }

    @Test("Conservative keeps only highConfidence")
    func conservativeKeepsHighOnly() {
        let (preds, rel) = Self.sample()
        let kept = BusPredictionFilter.filter(preds, reliabilities: rel, level: .conservative)
        #expect(kept.map(\.id) == ["h"])
    }

    @Test("Balanced keeps high + medium")
    func balancedKeepsHighAndMedium() {
        let (preds, rel) = Self.sample()
        let kept = BusPredictionFilter.filter(preds, reliabilities: rel, level: .balanced)
        #expect(kept.map(\.id) == ["h", "m"])
    }

    @Test("Inclusive keeps everything except doNotDisplay")
    func inclusiveKeepsAllExceptDoNotDisplay() {
        let (preds, rel) = Self.sample()
        let kept = BusPredictionFilter.filter(preds, reliabilities: rel, level: .inclusive)
        #expect(kept.map(\.id) == ["h", "m", "l", "u"])
    }

    @Test("Show all keeps everything")
    func showAllKeepsEverything() {
        let (preds, rel) = Self.sample()
        let kept = BusPredictionFilter.filter(preds, reliabilities: rel, level: .showAll)
        #expect(kept.map(\.id) == ["h", "m", "l", "u", "x"])
    }

    @Test("Unscored predictions pass through at every level")
    func unscoredPassesThrough() {
        let preds = [Self.prediction("orphan")]
        let rel: [String: BusArrivalReliability] = [:]
        for level in BusPredictionFilterLevel.allCases {
            let kept = BusPredictionFilter.filter(preds, reliabilities: rel, level: level)
            #expect(kept.count == 1, "unscored row should survive at level \(level)")
        }
    }

    @Test("Default level is inclusive")
    func defaultLevelIsInclusive() {
        #expect(BusPredictionFilterLevel.default == .inclusive)
    }

    // MARK: - Debug format

    @Test("Debug line format includes eta, state glyph, score, top reasons")
    func debugLineFormat() {
        let pred = Self.prediction("h")
        let rel = BusArrivalReliability(
            id: "h",
            state: .highConfidence,
            score: 0.81,
            reasonCodes: [.vehicleFresh, .routeMatch, .patternMatch, .predictionFresh]
        )
        let line = BusReliabilityDebugFormat.line(
            for: pred,
            reliability: rel,
            now: Self.now
        )
        // ETA is 5 minutes (300 s) at start, "H" for highConfidence,
        // 0.81 score, top 3 reasons joined by comma.
        #expect(line == " 5m  H 0.81  VEHICLE_FRESH,ROUTE_MATCH,PATTERN_MATCH")
    }

    @Test("Debug line falls back to unscored when no reliability is attached")
    func debugLineUnscored() {
        let pred = Self.prediction("orphan")
        let line = BusReliabilityDebugFormat.line(
            for: pred,
            reliability: nil,
            now: Self.now
        )
        #expect(line == " 5m  unscored")
    }

    @Test("Debug line uses X glyph for doNotDisplay")
    func debugLineCancelled() {
        let pred = Self.prediction("x")
        let rel = Self.reliability("x", .doNotDisplay, score: 0.05)
        let line = BusReliabilityDebugFormat.line(
            for: pred,
            reliability: rel,
            now: Self.now
        )
        #expect(line.contains("X 0.05"))
    }
}
