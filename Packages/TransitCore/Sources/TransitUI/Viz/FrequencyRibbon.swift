import ChicagoTheme
import SwiftUI

/// A Tufte-style sparkline of recent headways (the gap between
/// successive vehicles), showing whether service has been steady or
/// erratic. Each bar's height is proportional to its headway interval;
/// an optional dashed `target` line shows the scheduled headway for
/// comparison. Bars exceeding the target are coloured `starRed`.
///
/// Use to answer "is service running as expected?" — when bars are
/// flat the line is reliable; when they spike + drop, vehicles are
/// bunching.
public struct FrequencyRibbon: View {
    private let headways: [TimeInterval]
    private let target: TimeInterval?
    private let accent: Color

    public init(headways: [TimeInterval], target: TimeInterval? = nil, accent: Color) {
        self.headways = headways
        self.target = target
        self.accent = accent
    }

    public var body: some View {
        let maxValue = max(
            headways.max() ?? 1,
            (target ?? 0) * 1.2,
            1
        )
        GeometryReader { geo in
            let count = max(headways.count, 1)
            let barSpacing: CGFloat = 2
            let totalSpacing = barSpacing * CGFloat(count - 1)
            let barWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(count))
            ZStack(alignment: .bottom) {
                if let target {
                    let y = geo.size.height * (1 - target / maxValue)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(
                        ChicagoPalette.Gray.light,
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])
                    )
                }
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(Array(headways.enumerated()), id: \.offset) { _, value in
                        Rectangle()
                            .fill(barColor(for: value))
                            .frame(
                                width: barWidth,
                                height: geo.size.height * (value / maxValue)
                            )
                    }
                }
            }
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleSummary)
    }

    private func barColor(for value: TimeInterval) -> Color {
        if let target, value > target * 1.5 { return ChicagoPalette.starRed }
        if let target, value > target * 1.15 { return ChicagoPalette.gold }
        return accent
    }

    private var accessibleSummary: String {
        guard !headways.isEmpty else { return "No headway data" }
        let avg = headways.reduce(0, +) / Double(headways.count) / 60
        let max = (headways.max() ?? 0) / 60
        return String(
            format: "Recent headways: %.0f minute average, %.0f minute longest",
            avg, max
        )
    }
}
