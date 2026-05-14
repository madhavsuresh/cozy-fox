import ChicagoTheme
import SwiftUI
import TransitModels

public struct AlertBadge: View {
    public let alerts: [ServiceAlert]

    public init(alerts: [ServiceAlert]) {
        self.alerts = alerts
    }

    public var body: some View {
        if alerts.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: ChicagoSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .accessibilityHidden(true)
                Text("\(alerts.count) \(alerts.count == 1 ? "alert" : "alerts")")
                    .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
            }
            .padding(.horizontal, ChicagoSpacing.sm)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: ChicagoSpacing.Radius.sm))
            .foregroundStyle(badgeColor)
            .accessibilityLabel(
                "\(alerts.count) service \(alerts.count == 1 ? "alert" : "alerts")"
            )
        }
    }

    private var badgeColor: Color {
        let highest = alerts.map(\.severity).max(by: severityOrder)
        switch highest ?? .low {
        case .high:   return ChicagoPalette.starRed
        case .medium: return ChicagoPalette.gold
        case .low:    return ChicagoPalette.bahama
        }
    }

    private func severityOrder(_ a: AlertSeverity, _ b: AlertSeverity) -> Bool {
        rank(a) < rank(b)
    }

    private func rank(_ s: AlertSeverity) -> Int {
        switch s { case .low: 0; case .medium: 1; case .high: 2 }
    }
}
