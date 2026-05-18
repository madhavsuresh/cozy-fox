import Testing
import TransitModels
import TransitDomain
@testable import TransitUI

/// The dot strip exposes three pure-function helpers that drive its
/// "hue = trust, position+size = urgency" glance affordance. These
/// tests pin the ladder so a future tuning pass can't silently flip
/// it — a regression where `.likelyGhost` accidentally renders more
/// saturated than `.unconfirmed` would tell the rider exactly the
/// wrong story.
@Suite("HeadwayDotStrip complication ladder")
struct HeadwayDotStripComplicationTests {

    // MARK: - Trust blend

    @Test("nil keeps the full route accent")
    func nilComplicationFullAccent() {
        #expect(HeadwayDotStrip.trustBlend(for: nil) == 1.0)
    }

    @Test("confirmed and tracked both render at full accent")
    func positiveStatesFullAccent() {
        #expect(HeadwayDotStrip.trustBlend(for: .confirmed) == 1.0)
        #expect(HeadwayDotStrip.trustBlend(for: .tracked) == 1.0)
    }

    @Test("cancelled flattens to neutral entirely")
    func cancelledFullyNeutral() {
        #expect(HeadwayDotStrip.trustBlend(for: .cancelled) == 0.0)
    }

    @Test("ladder is monotonic non-increasing from confirmed → cancelled")
    func ladderIsMonotonic() {
        // Reading left to right: each step is "at least as untrustworthy"
        // as the previous one. Equality is allowed (confirmed ==
        // tracked share the full-accent slot) but a flip would mean a
        // glance reads `.likelyGhost` as *more* reliable than
        // `.unconfirmed`, which is exactly the failure mode we want to
        // guard against.
        let ladder: [HeadwayDotStrip.Complication] = [
            .confirmed, .tracked, .unconfirmed, .likelyGhost, .cancelled,
        ]
        let values = ladder.map { HeadwayDotStrip.trustBlend(for: $0) }
        for (lhs, rhs) in zip(values, values.dropFirst()) {
            #expect(lhs >= rhs, "ladder regression: \(values)")
        }
    }

    @Test("uncertain states sit strictly between confirmed and cancelled")
    func uncertainStatesBracketed() {
        let unconfirmed = HeadwayDotStrip.trustBlend(for: .unconfirmed)
        let ghost = HeadwayDotStrip.trustBlend(for: .likelyGhost)
        #expect(unconfirmed > 0 && unconfirmed < 1)
        #expect(ghost > 0 && ghost < unconfirmed)
    }

    // MARK: - Glyph vocabulary

    @Test("both positive states share the checkmark glyph")
    func positiveStatesShareGlyph() {
        // The ladder reads confirmed → tracked → unconfirmed → ! → X.
        // Confirmed and tracked are both "✓"; the difference is hue
        // saturation on the badge, not the glyph. If a future change
        // gives them different glyphs we'd want it to be explicit, not
        // accidental.
        #expect(HeadwayDotStrip.glyphSymbol(for: .confirmed) == "checkmark")
        #expect(HeadwayDotStrip.glyphSymbol(for: .tracked) == "checkmark")
    }

    @Test("uncertain states get question and exclamation")
    func uncertainStatesUseQuestionAndBang() {
        #expect(HeadwayDotStrip.glyphSymbol(for: .unconfirmed) == "questionmark")
        #expect(HeadwayDotStrip.glyphSymbol(for: .likelyGhost) == "exclamationmark")
    }

    @Test("cancelled uses xmark — distinct glyph from likelyGhost")
    func cancelledUsesXmark() {
        #expect(HeadwayDotStrip.glyphSymbol(for: .cancelled) == "xmark")
        // Same hue family (red) as likelyGhost, distinct glyph so the
        // ladder reads `!` (warning) vs `X` (verdict).
        #expect(
            HeadwayDotStrip.glyphSymbol(for: .cancelled)
                != HeadwayDotStrip.glyphSymbol(for: .likelyGhost)
        )
    }

    // MARK: - Glyph contrast

    @Test("unconfirmed badge uses dark glyph (gold needs black for contrast)")
    func unconfirmedUsesDarkGlyph() {
        #expect(HeadwayDotStrip.glyphUsesLightForeground(for: .unconfirmed) == false)
    }

    @Test("green and red badges use light glyph for stable contrast")
    func saturatedBadgesUseLightGlyph() {
        #expect(HeadwayDotStrip.glyphUsesLightForeground(for: .confirmed))
        #expect(HeadwayDotStrip.glyphUsesLightForeground(for: .tracked))
        #expect(HeadwayDotStrip.glyphUsesLightForeground(for: .likelyGhost))
        #expect(HeadwayDotStrip.glyphUsesLightForeground(for: .cancelled))
    }
}

/// The bus and train reliability ladders are meant to render
/// identically — riders shouldn't have to learn a second vocabulary
/// when they pin a bus alongside their trains. These tests pin the
/// state → complication mapping for both modes so a future change to
/// one side has to consciously update the other (or these tests).
@Suite("Bus/train reliability ladder parity")
struct ReliabilityHeadwayComplicationParityTests {

    @Test("bus and train high-confidence both produce .confirmed")
    func highConfidenceConfirmedBothModes() {
        #expect(busReliability(.highConfidence).headwayComplication == .confirmed)
        #expect(trainReliability(.highConfidence).headwayComplication == .confirmed)
    }

    @Test("bus and train medium-confidence both produce .tracked")
    func mediumConfidenceTrackedBothModes() {
        #expect(busReliability(.mediumConfidence).headwayComplication == .tracked)
        #expect(trainReliability(.mediumConfidence).headwayComplication == .tracked)
    }

    @Test("bus and train low-confidence both produce .unconfirmed")
    func lowConfidenceUnconfirmedBothModes() {
        #expect(busReliability(.lowConfidence).headwayComplication == .unconfirmed)
        #expect(trainReliability(.lowConfidence).headwayComplication == .unconfirmed)
    }

    @Test("bus and train unreliable both produce .likelyGhost")
    func unreliableGhostBothModes() {
        #expect(busReliability(.unreliable).headwayComplication == .likelyGhost)
        #expect(trainReliability(.unreliable).headwayComplication == .likelyGhost)
    }

    @Test("bus and train doNotDisplay both produce .cancelled")
    func doNotDisplayCancelledBothModes() {
        #expect(busReliability(.doNotDisplay).headwayComplication == .cancelled)
        #expect(trainReliability(.doNotDisplay).headwayComplication == .cancelled)
    }

    // MARK: - Fixture helpers

    private func busReliability(_ state: BusArrivalReliability.State) -> BusArrivalReliability {
        BusArrivalReliability(
            id: "test-bus-\(state.rawValue)",
            state: state,
            score: 0.5,
            reasonCodes: []
        )
    }

    private func trainReliability(_ state: TrainArrivalReliability.State) -> TrainArrivalReliability {
        TrainArrivalReliability(
            id: "test-train-\(state.rawValue)",
            state: state,
            score: 0.5,
            reasonCodes: []
        )
    }
}
