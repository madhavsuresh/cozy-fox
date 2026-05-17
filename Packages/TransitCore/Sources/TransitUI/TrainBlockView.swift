import ChicagoTheme
import SwiftUI
import TransitModels
import TransitDomain

public extension TrainArrivalReliability {
    /// Map the per-arrival reliability state onto the dot-strip
    /// complication vocabulary. Mirror of
    /// `BusArrivalReliability.headwayComplication` — keeping the two
    /// modes visually identical so the rider doesn't have to learn a
    /// separate vocabulary for trains.
    ///
    /// - `.highConfidence`: green `✓` — strongest positive.
    /// - `.mediumConfidence`: muted-green `✓` — observed but a step
    ///   below confirmed.
    /// - `.lowConfidence`: gold `?` — soft uncertainty (e.g. CTA's
    ///   `isFlt` or `isSch` on a tracked run).
    /// - `.unreliable`: red `!` — strong uncertainty.
    /// - `.doNotDisplay`: red `X` — positively-wrong row. Normally
    ///   filtered out; only renders at "Show everything."
    var headwayComplication: HeadwayDotStrip.Complication? {
        switch state {
        case .highConfidence:
            .confirmed
        case .mediumConfidence:
            .tracked
        case .lowConfidence:
            .unconfirmed
        case .unreliable:
            .likelyGhost
        case .doNotDisplay:
            .cancelled
        }
    }
}

public struct TrainBlockView: View {
    public let arrivals: [Arrival]
    public let title: String
    public let directionLabel: String?
    public let now: Date
    public let vehiclePositions: [VehiclePosition]
    public let arrivalsFetchedAt: Date?
    /// Phase 3 bias correction for the headline arrival.
    public let biasCorrection: ArrivalBiasCorrection?
    /// Optional per-arrival reliability. When provided, weak rows
    /// hide the BigNumber and lean on the dot strip so the rider
    /// doesn't see a confident countdown for an arrival we can't
    /// back up. When `nil`, the view runs `TrainReliabilityScorer`
    /// with defaults so legacy callers still get badges — mirrors
    /// the bus side's external-data pattern but with a fallback so
    /// the widget doesn't go silent.
    public let reliabilities: [String: TrainArrivalReliability]?
    /// Active CTA service alerts. Only consulted by the internal
    /// fallback scorer; external callers that pass `reliabilities`
    /// have already factored alerts in.
    public let alerts: [ServiceAlert]
    /// Power-user toggle: renders a small monospaced debug line
    /// under the dot strip showing each arrival's reliability state,
    /// score, and top reason codes. Off by default.
    public let showReliabilityDebug: Bool

    public init(arrivals: [Arrival],
                title: String,
                directionLabel: String?,
                now: Date = .now,
                vehiclePositions: [VehiclePosition] = [],
                arrivalsFetchedAt: Date? = nil,
                biasCorrection: ArrivalBiasCorrection? = nil,
                reliabilities: [String: TrainArrivalReliability]? = nil,
                alerts: [ServiceAlert] = [],
                showReliabilityDebug: Bool = false) {
        self.arrivals = arrivals
        self.title = title
        self.directionLabel = directionLabel
        self.now = now
        self.vehiclePositions = vehiclePositions
        self.arrivalsFetchedAt = arrivalsFetchedAt
        self.biasCorrection = biasCorrection
        self.reliabilities = reliabilities
        self.alerts = alerts
        self.showReliabilityDebug = showReliabilityDebug
    }

    public var body: some View {
        let line = arrivals.first?.line ?? .red
        let resolvedReliabilities = reliabilities ?? TrainReliabilityScorer()
            .catalogedAssessments(
                for: arrivals,
                vehiclePositions: vehiclePositions,
                alerts: alerts,
                now: now
            )
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                RouteBadge(line: line, size: .sm)
                Text(title)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let directionLabel {
                Text(directionLabel)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let first = arrivals.first {
                let topReliability = resolvedReliabilities[first.id]
                let suppressBigNumber = topReliability?.needsMutedStyling ?? false
                if !suppressBigNumber {
                    let minutes = max(0, Int((first.arrivalAt.timeIntervalSince(now) / 60).rounded()))
                    HStack(alignment: .lastTextBaseline, spacing: ChicagoSpacing.xs) {
                        BigNumber(
                            minutes,
                            unit: "min",
                            size: .md,
                            tone: first.isDelayed ? .alert : .primary,
                            accessibilityLabel: "\(minutes) minutes to next \(line.displayName) train"
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
                    arrivals: arrivals.prefix(8).map(\.arrivalAt),
                    accent: line.swiftUIColor,
                    now: now,
                    complications: arrivals.prefix(8).map {
                        resolvedReliabilities[$0.id]?.headwayComplication
                    }
                )
                if showReliabilityDebug {
                    TrainReliabilityDebugOverlay(
                        arrivals: Array(arrivals.prefix(4)),
                        reliabilities: resolvedReliabilities,
                        now: now
                    )
                }
            } else {
                Text("No data")
                    .font(ChicagoTypography.body(.medium, relativeTo: .footnote))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Tiny monospaced overlay showing reliability state, score, and top
/// reason codes for each arrival. Mirror of `BusReliabilityDebugOverlay`.
///
/// Format per line: `"<eta>m  <state> <score>  <reasons>"`.
public struct TrainReliabilityDebugOverlay: View {
    public let arrivals: [Arrival]
    public let reliabilities: [String: TrainArrivalReliability]
    public let now: Date
    public let maxRows: Int

    public init(
        arrivals: [Arrival],
        reliabilities: [String: TrainArrivalReliability],
        now: Date = .now,
        maxRows: Int = 4
    ) {
        self.arrivals = arrivals
        self.reliabilities = reliabilities
        self.now = now
        self.maxRows = maxRows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(arrivals.prefix(maxRows)), id: \.id) { arrival in
                Text(TrainReliabilityDebugFormat.line(
                    for: arrival,
                    reliability: reliabilities[arrival.id],
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

#Preview {
    TrainBlockView(
        arrivals: [
            Arrival(
                id: "1", line: .red, runNumber: "418",
                destinationName: "95th/Dan Ryan", stationId: 40380,
                stationName: "Clark/Division", stopId: 30074,
                directionCode: "1",
                predictedAt: .now, arrivalAt: .now.addingTimeInterval(240),
                isApproaching: false, isDelayed: false, isFault: false, isScheduled: false
            ),
            Arrival(
                id: "2", line: .red, runNumber: "419",
                destinationName: "95th/Dan Ryan", stationId: 40380,
                stationName: "Clark/Division", stopId: 30074,
                directionCode: "1",
                predictedAt: .now, arrivalAt: .now.addingTimeInterval(720),
                isApproaching: false, isDelayed: false, isFault: false, isScheduled: false
            ),
        ],
        title: "Clark/Division",
        directionLabel: "→ 95th"
    )
    .frame(width: 150, height: 150)
}
