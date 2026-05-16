import Foundation
import Testing
@testable import TransitModels

@Suite("PredictionLog")
struct PredictionLogTests {
    @Test func openEpisodeAcceptsAppendsAndStaysOpen() {
        let initial = JourneyEpisodeLog(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(initial.isOpen)
        let entry = PredictionLogEntry(
            predictionID: UUID(),
            loggedAt: Date(timeIntervalSinceReferenceDate: 5),
            kind: .request,
            payloadJSON: "{}"
        )
        let appended = initial.appending(entry)
        #expect(appended.entries.count == 1)
        #expect(appended.isOpen)
    }

    @Test func closedEpisodeReportsClosed() {
        let log = JourneyEpisodeLog(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let closed = log.closed(at: Date(timeIntervalSinceReferenceDate: 100), actualOutcomeJSON: "{\"ok\":true}")
        #expect(!closed.isOpen)
        #expect(closed.closedAt?.timeIntervalSinceReferenceDate == 100)
        #expect(closed.actualOutcomeJSON == "{\"ok\":true}")
    }

    @Test func codableRoundTrip() throws {
        let log = JourneyEpisodeLog(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            closedAt: Date(timeIntervalSinceReferenceDate: 100),
            entries: [
                PredictionLogEntry(
                    predictionID: UUID(),
                    loggedAt: Date(timeIntervalSinceReferenceDate: 10),
                    kind: .recommendation,
                    optionID: UUID(),
                    payloadJSON: "{\"x\":1}"
                )
            ],
            actualOutcomeJSON: "{\"ok\":true}"
        )
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(JourneyEpisodeLog.self, from: data)
        #expect(decoded == log)
    }
}
