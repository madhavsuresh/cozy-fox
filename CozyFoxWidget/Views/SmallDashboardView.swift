import ChicagoTheme
import SwiftUI
import TransitDomain
import TransitModels
import TransitUI

/// Small widget — the punchiest surface in the app. One headline number
/// in Big Shoulders Display, a route badge, a destination, and a tiny
/// headway dot-strip if there's more than one upcoming arrival.
struct SmallDashboardView: View {
    let entry: DashboardEntry

    var body: some View {
        if let arrival = displayedTrainArrival {
            let line = arrival.line
            let upcoming = displayedTrainArrivals
                .prefix(8)
                .map(\.arrivalAt)
            let minutes = max(0, Int((arrival.arrivalAt.timeIntervalSince(entry.date) / 60).rounded()))
            let hasAlert = entry.snapshot.activeAlerts.contains {
                $0.impactedLineColors.contains(line)
            }
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                    RouteBadge(line: line, size: .sm)
                    Spacer()
                    if hasAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(ChicagoPalette.starRed)
                            .accessibilityLabel("Alert")
                    }
                }
                Text(arrival.destinationName)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                BigNumber(
                    minutes,
                    unit: "min",
                    size: .lg,
                    tone: arrival.isDelayed ? .alert : .primary,
                    accessibilityLabel: "\(minutes) minutes to next \(line.displayName) train"
                )
                HeadwayDotStrip(
                    arrivals: Array(upcoming),
                    accent: line.swiftUIColor,
                    now: entry.date
                )
            }
            .padding(ChicagoSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let metraGroup = displayedMetraGroup {
            let upcoming = metraGroup.departures
                .prefix(8)
                .map(\.arrivalAt)
            let hasAlert = entry.snapshot.activeAlerts.contains {
                $0.impactedRoutes.contains(metraGroup.routeId)
            }
            VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
                HStack(alignment: .center, spacing: ChicagoSpacing.xs) {
                    RouteBadge(metra: metraGroup.routeId, size: .sm)
                    Spacer()
                    if hasAlert {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(ChicagoPalette.starRed)
                            .accessibilityLabel("Alert")
                    }
                }
                Text(metraGroup.title)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                if let terminalSummary = metraGroup.terminalSummary {
                    Text(terminalSummary)
                        .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                        .foregroundStyle(ChicagoPalette.Gray.medium)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                MetraDepartureTimesView(
                    predictions: metraGroup.departures,
                    maxCount: 3,
                    size: .sm,
                    accessibilityPrefix: "Metra \(metraGroup.title.lowercased()) departures at"
                )
                HeadwayDotStrip(
                    arrivals: Array(upcoming),
                    accent: MetraStationCatalog.route(id: metraGroup.routeId)?.swiftUIColor ?? ChicagoPalette.bahama,
                    now: entry.date
                )
            }
            .padding(ChicagoSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let pick = entry.snapshot.nearestBike {
            BikeBlockView(pick: pick)
        } else {
            VStack(spacing: ChicagoSpacing.xs) {
                ChicagoStar()
                    .fill(ChicagoPalette.cornflower)
                    .frame(width: 28, height: 28)
                Text("No data yet")
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var displayedTrainArrivals: [Arrival] {
        if let tripTrain = entry.preferences.plannedTripPin?.train {
            return entry.snapshot.trainArrivals
                .filter { $0.line == tripTrain.line }
                .filter { tripTrain.stationId == nil || $0.stationId == tripTrain.stationId }
                .filter { tripTrain.destinationName == nil || $0.destinationName == tripTrain.destinationName }
        }
        guard let first = entry.snapshot.trainArrivals.first else { return [] }
        return entry.snapshot.trainArrivals.filter { $0.line == first.line }
    }

    private var displayedTrainArrival: Arrival? {
        displayedTrainArrivals.first
    }

    private var displayedMetraPredictions: [MetraPrediction] {
        if let tripMetra = entry.preferences.plannedTripPin?.metra {
            return entry.snapshot.metraPredictions
                .filter { $0.routeId == tripMetra.routeId }
                .filter { tripMetra.stationId == nil || $0.stationId == tripMetra.stationId }
                .filter { tripMetra.directionId == nil || $0.directionId == tripMetra.directionId }
        }
        guard let first = entry.snapshot.metraPredictions.first else { return [] }
        return entry.snapshot.metraPredictions.filter {
            $0.routeId == first.routeId && $0.stationId == first.stationId
        }
    }

    private var displayedMetraGroup: MetraDepartureGroup? {
        MetraDepartureGrouper.groups(from: displayedMetraPredictions, limitPerGroup: 3).first
    }
}
