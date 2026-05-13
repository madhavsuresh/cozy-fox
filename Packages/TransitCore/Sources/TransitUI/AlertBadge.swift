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
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("\(alerts.count) alert\(alerts.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.2), in: Capsule())
            .foregroundStyle(badgeColor)
        }
    }

    private var badgeColor: Color {
        let highest = alerts.map(\.severity).max(by: severityOrder)
        switch highest ?? .low {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        }
    }

    private func severityOrder(_ a: AlertSeverity, _ b: AlertSeverity) -> Bool {
        rank(a) < rank(b)
    }

    private func rank(_ s: AlertSeverity) -> Int {
        switch s { case .low: 0; case .medium: 1; case .high: 2 }
    }
}
