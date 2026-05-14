import ChicagoTheme
import SwiftUI
import TransitDomain

public struct GhostTrainBadge: View {
    private let assessment: GhostTrainAssessment

    public init?(_ assessment: GhostTrainAssessment?) {
        guard let assessment, assessment.needsRiderAttention else { return nil }
        self.assessment = assessment
    }

    public var body: some View {
        Label(title, systemImage: symbolName)
            .font(ChicagoTypography.body(.medium, relativeTo: .caption2))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        switch assessment.status {
        case .likelyGhost:
            "Likely ghost"
        case .unconfirmed:
            "Unconfirmed"
        case .staleFeed:
            "Feed stale"
        case .live, .scheduledOnly:
            ""
        }
    }

    private var symbolName: String {
        switch assessment.status {
        case .likelyGhost:
            "exclamationmark.triangle.fill"
        case .unconfirmed:
            "questionmark.circle.fill"
        case .staleFeed:
            "clock.fill"
        case .live, .scheduledOnly:
            "checkmark.circle.fill"
        }
    }

    private var foreground: Color {
        switch assessment.status {
        case .likelyGhost:
            ChicagoPalette.starRed
        case .unconfirmed:
            ChicagoPalette.Gray.darkest
        case .staleFeed:
            ChicagoPalette.Gray.dark
        case .live, .scheduledOnly:
            ChicagoPalette.Gray.medium
        }
    }

    private var background: Color {
        switch assessment.status {
        case .likelyGhost:
            ChicagoPalette.starRed.opacity(0.12)
        case .unconfirmed:
            ChicagoPalette.gold.opacity(0.22)
        case .staleFeed:
            ChicagoPalette.Gray.light.opacity(0.18)
        case .live, .scheduledOnly:
            ChicagoPalette.Gray.light.opacity(0.12)
        }
    }

    private var accessibilityLabel: String {
        "\(title). \(assessment.reason)"
    }
}

extension GhostTrainAssessment {
    public var headwayComplication: HeadwayDotStrip.Complication? {
        switch status {
        case .likelyGhost:
            .likelyGhost
        case .unconfirmed:
            .unconfirmed
        case .staleFeed:
            .stale
        case .live, .scheduledOnly:
            nil
        }
    }
}
