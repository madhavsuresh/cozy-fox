import SwiftUI

/// The six-pointed Chicago star from the municipal flag, rendered as a
/// SwiftUI `Shape` so it's resolution-independent and animatable.
///
/// Geometry per Municipal Code Chapter 1-8: outer points lie on a circle,
/// inner concave points lie on a circle whose diameter is 6 units to the
/// star's 14-unit bounding box height. The first point is "up" (12
/// o'clock).
///
/// Use it for the user's stop marker on transit progress strips, as an
/// ornament in headers, as the loading indicator, and as the empty-state
/// glyph. **Always** fill with `ChicagoPalette.starRed` unless you have a
/// very specific reason not to — Chicagoans recognise the symbol *and*
/// the colour together.
public struct ChicagoStar: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        // 6:14 ratio from the spec.
        let inner = outer * (6.0 / 14.0)
        let points = 6
        let stepAngle = .pi / Double(points)

        for i in 0..<(points * 2) {
            let isOuter = i.isMultiple(of: 2)
            let radius = isOuter ? outer : inner
            // First outer point straight up; subsequent vertices alternate
            // outer/inner every 30°.
            let angle = -Double.pi / 2 + stepAngle * Double(i)
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
