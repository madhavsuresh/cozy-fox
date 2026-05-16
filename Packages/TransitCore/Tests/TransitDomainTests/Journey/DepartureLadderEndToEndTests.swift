import Foundation
import Testing
@testable import TransitCache
@testable import TransitDomain
@testable import TransitModels

@Suite("Departure ladder end-to-end synthetic")
struct DepartureLadderEndToEndTests {
    private static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Hand-built ladder for Home → Work using one Red Line candidate plus
    /// an alternate Brown Line candidate. Validates the substrate composes
    /// without touching any UI layer.
    @Test func redLineAndBrownLineProduceFiveOrderedRowsAndAnnotatedLadder() {
        let clock = FakeClock(Self.t0)
        let walkingFetcher: @Sendable (JourneyPoint, JourneyPoint) -> TimeInterval = { _, _ in 240 }
        let builder = DepartureLadderBuilder()

        let redDepartures: [LiveDeparture] = [7, 15, 23, 31, 41].map {
            LiveDeparture(arrivalAt: Self.t0.addingTimeInterval($0 * 60))
        }
        let brownDepartures: [LiveDeparture] = [11, 22, 33].map {
            LiveDeparture(arrivalAt: Self.t0.addingTimeInterval($0 * 60))
        }

        let red = LadderCandidateSpec(
            title: "Red Line — Belmont",
            mode: .ctaTrain,
            routeIdentifier: "Red",
            direction: "Howard",
            boardingPoint: .station(systemRef: "40360", name: "Belmont", lineHint: "Red"),
            alightingPoint: .station(systemRef: "40330", name: "Roosevelt", lineHint: "Red"),
            inVehicleSeconds: 1320,
            inVehicleSigmaSeconds: 120,
            finalMileSeconds: 540,
            finalMileSigmaSeconds: 30,
            scheduleHeadwaySeconds: 480,
            liveDepartures: redDepartures,
            feedState: .fresh
        )
        let brown = LadderCandidateSpec(
            title: "Brown Line — Diversey",
            mode: .ctaTrain,
            routeIdentifier: "Brn",
            direction: "Loop",
            boardingPoint: .station(systemRef: "40530", name: "Diversey", lineHint: "Brn"),
            alightingPoint: .station(systemRef: "40380", name: "Washington/Wells", lineHint: "Brn"),
            inVehicleSeconds: 1620,
            inVehicleSigmaSeconds: 180,
            finalMileSeconds: 720,
            finalMileSigmaSeconds: 60,
            scheduleHeadwaySeconds: 660,
            liveDepartures: brownDepartures,
            feedState: .fresh
        )

        let ladder = builder.build(
            destinationTitle: "Work",
            origin: .anchor(.home),
            snapshot: .empty,
            candidates: [red, brown],
            walkSpeedEstimate: .empty,
            walkingTimeFetcher: walkingFetcher,
            clock: clock
        )

        #expect(ladder.destinationTitle == "Work")
        #expect(ladder.rows.count == 5)
        #expect(ladder.lineHealth.count == 2)

        let leaveBys = ladder.rows.map { $0.leaveByAt }
        #expect(leaveBys == leaveBys.sorted())

        for row in ladder.rows {
            #expect(row.totalDuration.p50 > 0)
            #expect(row.totalDuration.p80 >= row.totalDuration.p50)
            #expect(row.arrivalAt.low <= row.arrivalAt.high)
        }

        print("--- Departure ladder ---")
        print("destination: \(ladder.destinationTitle)")
        if let headline = ladder.headline { print("headline: \(headline)") }
        for row in ladder.rows {
            let leaveBy = row.leaveByAt.timeIntervalSince(Self.t0) / 60
            let arrivalLow = row.arrivalAt.low.timeIntervalSince(Self.t0) / 60
            let arrivalHigh = row.arrivalAt.high.timeIntervalSince(Self.t0) / 60
            print(String(
                format: "  leave +%4.1f min  arrive +%4.1f-%4.1f min  %@  risk=%@",
                leaveBy, arrivalLow, arrivalHigh,
                row.primaryLabel,
                row.risk.rawValue
            ))
        }
        for health in ladder.lineHealth {
            print("  line=\(health.route) state=\(health.state.rawValue) conf=\(health.confidence)")
        }
    }
}
