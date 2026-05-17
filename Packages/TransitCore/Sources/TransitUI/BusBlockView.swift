import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public extension BusArrivalReliability {
    /// Map the per-prediction reliability state onto the dot-strip
    /// complication vocabulary so each dot styles itself according to
    /// how much we trust the underlying arrival. Mirrors
    /// `GhostTrainAssessment.headwayComplication` for parity between
    /// the train and bus surfaces.
    ///
    /// Visual contract:
    /// - `.highConfidence` / `.mediumConfidence`: no complication, dot
    ///   renders with its accent color at full opacity.
    /// - `.lowConfidence`: gold ring + `?` badge — soft uncertainty
    ///   (e.g. CTA `dyn` flag on a tracked vehicle, or no vehicle on
    ///   a far-out prediction).
    /// - `.unreliable`: red ring + `!` badge — strong uncertainty,
    ///   matches the "scheduled-only" buses Google Maps marks red.
    /// - `.doNotDisplay`: red ring + `X` badge — positively-wrong row
    ///   (already passed, stop removed by detour, due-but-far, etc.).
    ///   Normally filtered out before the strip sees it; only renders
    ///   when the filter level is set to "Show everything."
    var headwayComplication: HeadwayDotStrip.Complication? {
        switch state {
        case .highConfidence, .mediumConfidence:
            nil
        case .lowConfidence:
            .unconfirmed
        case .unreliable:
            .likelyGhost
        case .doNotDisplay:
            .cancelled
        }
    }
}

public struct BusBlockView: View {
    public let predictions: [BusPrediction]
    public let routeLabel: String
    public let stopLabel: String
    public let now: Date
    /// Phase 3 bias correction for the headline prediction. See
    /// `TrainBlockView.biasCorrection` for the contract.
    public let biasCorrection: ArrivalBiasCorrection?
    /// Optional per-prediction reliability. When provided, weak rows
    /// hide the BigNumber and lean on the dot strip so the rider
    /// doesn't see a confident countdown for a prediction we can't
    /// back up. Row filtering itself happens upstream via
    /// `BusPredictionFilter` so `BusBlockView` renders whatever it
    /// receives. See `docs/BUS_RELIABILITY.md`.
    public let reliabilities: [String: BusArrivalReliability]?
    /// Power-user toggle: when true, renders a small monospaced
    /// debug line under the dot strip showing each prediction's
    /// reliability state, score, and top reason codes. Off by default.
    public let showReliabilityDebug: Bool

    public init(predictions: [BusPrediction],
                routeLabel: String,
                stopLabel: String,
                now: Date = .now,
                biasCorrection: ArrivalBiasCorrection? = nil,
                reliabilities: [String: BusArrivalReliability]? = nil,
                showReliabilityDebug: Bool = false) {
        self.predictions = predictions
        self.routeLabel = routeLabel
        self.stopLabel = stopLabel
        self.now = now
        self.biasCorrection = biasCorrection
        self.reliabilities = reliabilities
        self.showReliabilityDebug = showReliabilityDebug
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                RouteBadge(bus: routeLabel, size: .sm)
                Text(stopLabel)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Filtering by reliability now lives in
            // `BusPredictionFilter` (called upstream in
            // `AppViewModel.displayableBusPredictions`), so the block
            // renders whatever it receives. The dot strip's
            // complications still differentiate confident vs. flagged
            // rows visually.
            let shown = predictions
            if let first = shown.first {
                let topReliability = reliabilities?[first.id]
                let suppressBigNumber = topReliability?.needsMutedStyling ?? false
                if !suppressBigNumber {
                    let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(now) / 60).rounded()))
                    HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                        BigNumber(
                            minutes,
                            unit: "min",
                            size: .md,
                            tone: first.isDelayed ? .alert : .primary,
                            accessibilityLabel: "\(minutes) minutes to next bus on route \(routeLabel)"
                        )
                        if first.isDelayed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(ChicagoPalette.starRed)
                                .accessibilityHidden(true)
                        }
                    }
                    if let biasCorrection {
                        Text(biasCorrection.displayText)
                            .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                            .foregroundStyle(ChicagoPalette.Gray.medium)
                            .lineLimit(1)
                            .accessibilityLabel(biasCorrection.accessibilityLabel)
                    }
                }
                HeadwayDotStrip(
                    arrivals: shown.prefix(8).map(\.arrivalAt),
                    accent: ChicagoPalette.Mode.bus,
                    now: now,
                    complications: shown.prefix(8).map {
                        reliabilities?[$0.id]?.headwayComplication
                    }
                )
                if showReliabilityDebug, let reliabilities {
                    reliabilityDebugOverlay(
                        for: Array(shown.prefix(4)),
                        reliabilities: reliabilities
                    )
                }
            } else {
                Text("No buses")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func reliabilityDebugOverlay(
        for predictions: [BusPrediction],
        reliabilities: [String: BusArrivalReliability]
    ) -> some View {
        BusReliabilityDebugOverlay(
            predictions: predictions,
            reliabilities: reliabilities,
            now: now
        )
    }
}

/// Tiny monospaced overlay showing reliability state, score, and top
/// reason codes for each prediction. Used by `BusBlockView` and by the
/// dashboard's inline bus surfaces that compose their own views.
///
/// Format per line: `"<eta>m  <state> <score>  <reasons>"`, e.g.
/// `" 3m  H 0.81  VEHICLE_FRESH,ROUTE_MATCH,PATTERN_MATCH"`.
public struct BusReliabilityDebugOverlay: View {
    public let predictions: [BusPrediction]
    public let reliabilities: [String: BusArrivalReliability]
    public let now: Date
    public let maxRows: Int

    public init(
        predictions: [BusPrediction],
        reliabilities: [String: BusArrivalReliability],
        now: Date = .now,
        maxRows: Int = 4
    ) {
        self.predictions = predictions
        self.reliabilities = reliabilities
        self.now = now
        self.maxRows = maxRows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(predictions.prefix(maxRows)), id: \.id) { pred in
                Text(BusReliabilityDebugFormat.line(
                    for: pred,
                    reliability: reliabilities[pred.id],
                    now: now
                ))
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
        }
    }
}
