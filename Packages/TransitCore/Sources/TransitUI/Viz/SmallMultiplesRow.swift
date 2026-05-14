import ChicagoTheme
import SwiftUI
import TransitModels

/// A horizontal row of identically-shaped tiles, each showing one
/// nearby route's next arrival. Tufte's **small multiples** principle
/// (1983) — the same chart drawn N times with the data varied — lets
/// the reader compare at a glance, with the tile *shape* as the
/// constant and the *content* as the variable.
///
/// Use under the "Near You" section: each tile is a `RouteBadge` +
/// `BigNumber` lockup, and they tile horizontally with consistent
/// rhythm. The eye sweeps left-to-right and reads the smallest number
/// first.
public struct SmallMultiplesRow<T: Identifiable>: View {
    public let items: [T]
    public let tile: (T) -> AnyView

    public init<TileView: View>(
        _ items: [T],
        @ViewBuilder tile: @escaping (T) -> TileView
    ) {
        self.items = items
        self.tile = { AnyView(tile($0)) }
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: ChicagoSpacing.sm) {
                ForEach(items) { item in
                    tile(item)
                        .frame(minWidth: 88, maxWidth: 120)
                }
            }
        }
    }
}

/// The standard tile used inside `SmallMultiplesRow` for transit
/// arrivals — a `RouteBadge` over a `BigNumber` "MIN" lockup, plus an
/// optional secondary line for direction or destination.
public struct ArrivalTile: View {
    public let badge: RouteBadge
    public let minutes: Int?
    public let subtitle: String?

    public init(badge: RouteBadge, minutes: Int?, subtitle: String? = nil) {
        self.badge = badge
        self.minutes = minutes
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            badge
            if let minutes {
                BigNumber(minutes, unit: "min", size: .md, tone: .primary,
                          accessibilityLabel: "\(minutes) minutes")
            } else {
                Text("—")
                    .font(ChicagoTypography.bigNumber(44))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
            if let subtitle {
                Text(subtitle)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(ChicagoPalette.cornflower.opacity(0.3),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
    }
}

/// Tile variant for scheduled departures where clock time is more useful
/// than relative minutes.
public struct DepartureTimeTile: View {
    public let badge: RouteBadge
    public let departureAt: Date?
    public let subtitle: String?
    public let isAlert: Bool

    public init(
        badge: RouteBadge,
        departureAt: Date?,
        subtitle: String? = nil,
        isAlert: Bool = false
    ) {
        self.badge = badge
        self.departureAt = departureAt
        self.subtitle = subtitle
        self.isAlert = isAlert
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            badge
            if let departureAt {
                MetraDepartureTimeView(
                    date: departureAt,
                    size: .md,
                    tone: isAlert ? .alert : .primary,
                    accessibilityPrefix: "Departs at"
                )
            } else {
                Text("—")
                    .font(ChicagoTypography.bigNumber(44))
                    .foregroundStyle(ChicagoPalette.Gray.light)
            }
            if let subtitle {
                Text(subtitle)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(minWidth: 88, maxWidth: 120, alignment: .leading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(ChicagoPalette.cornflower.opacity(0.3),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
    }
}

/// Tile variant for Metra direction groups, where the useful glance is the
/// next few clock departures instead of a single relative countdown.
public struct DepartureTimesTile: View {
    public let badge: RouteBadge
    public let title: String?
    public let departures: [MetraPrediction]
    public let subtitle: String?

    public init(
        badge: RouteBadge,
        title: String? = nil,
        departures: [MetraPrediction],
        subtitle: String? = nil
    ) {
        self.badge = badge
        self.title = title
        self.departures = departures
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ChicagoSpacing.xs) {
            badge
            if let title {
                Text(title)
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.darkest)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            MetraDepartureTimesView(
                predictions: departures,
                maxCount: 3,
                size: .sm,
                accessibilityPrefix: "Metra departures at"
            )
            if let subtitle {
                Text(subtitle)
                    .font(ChicagoTypography.body(.regular, relativeTo: .caption2))
                    .foregroundStyle(ChicagoPalette.Gray.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(ChicagoSpacing.sm)
        .frame(minWidth: 104, maxWidth: 144, alignment: .leading)
        .background(
            ChicagoPalette.Surface.card,
            in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.md)
                .strokeBorder(ChicagoPalette.cornflower.opacity(0.3),
                              lineWidth: ChicagoSpacing.Stroke.hairline)
        )
    }
}
