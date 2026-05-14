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
            let displayedArrivals = displayedTrainArrivals
            let upcoming = displayedArrivals.prefix(8).map(\.arrivalAt)
            let assessments = GhostTrainDetector().assessments(
                for: displayedArrivals,
                vehiclePositions: entry.snapshot.vehiclePositions,
                arrivalsFetchedAt: entry.snapshot.trainsFetchedAt,
                now: entry.date
            )
            let firstAssessment = assessments[arrival.id]
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
                    tone: arrival.isDelayed || firstAssessment?.isGhostLikely == true ? .alert : .primary,
                    accessibilityLabel: "\(minutes) minutes to next \(line.displayName) train"
                )
                if let badge = GhostTrainBadge(firstAssessment) {
                    badge
                }
                HeadwayDotStrip(
                    arrivals: Array(upcoming),
                    accent: line.swiftUIColor,
                    now: entry.date,
                    complications: displayedArrivals.prefix(8).map {
                        assessments[$0.id]?.headwayComplication
                    }
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
                Spacer(minLength: 0)
                MetraDepartureListView(
                    predictions: metraGroup.departures,
                    maxCount: 2,
                    density: .compact,
                    accessibilityPrefix: "Metra \(metraGroup.title.lowercased()) departures"
                )
                HeadwayDotStrip(
                    arrivals: Array(upcoming),
                    accent: MetraStationCatalog.route(id: metraGroup.routeId)?.swiftUIColor ?? ChicagoPalette.bahama,
                    now: entry.date
                )
            }
            .padding(ChicagoSpacing.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if entry.preferences.isModeVisible(.bikes),
                  let pick = entry.snapshot.nearestBike {
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
        if let pinned = entry.preferences.pinnedLine {
            return entry.snapshot.trainArrivals
                .filter { $0.line == pinned }
                .filter {
                    entry.preferences.pinnedStationId == nil
                        || $0.stationId == entry.preferences.pinnedStationId
                }
                .filter {
                    entry.preferences.pinnedTrainDestination == nil
                        || $0.destinationName == entry.preferences.pinnedTrainDestination
                }
        }
        guard entry.preferences.isModeVisible(.trains),
              let first = entry.snapshot.trainArrivals.first(where: {
                  entry.preferences.isTrainLineVisible($0.line)
              }) else { return [] }
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
        if let pinned = entry.preferences.pinnedMetraRoute {
            return entry.snapshot.metraPredictions
                .filter { $0.routeId == pinned }
                .filter {
                    entry.preferences.pinnedMetraStationId == nil
                        || $0.stationId == entry.preferences.pinnedMetraStationId
                }
                .filter {
                    entry.preferences.pinnedMetraDirectionId == nil
                        || $0.directionId == entry.preferences.pinnedMetraDirectionId
                }
        }
        guard entry.preferences.isModeVisible(.metra),
              let first = entry.snapshot.metraPredictions.first(where: {
                  entry.preferences.isMetraRouteVisible($0.routeId)
              }) else { return [] }
        return entry.snapshot.metraPredictions.filter {
            $0.routeId == first.routeId && $0.stationId == first.stationId
        }
    }

    private var displayedMetraGroup: MetraDepartureGroup? {
        MetraDepartureGrouper.groups(from: displayedMetraPredictions, limitPerGroup: 3).first
    }
}
