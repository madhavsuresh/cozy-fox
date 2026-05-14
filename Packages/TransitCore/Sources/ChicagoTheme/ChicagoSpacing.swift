import CoreGraphics

/// 8-point spacing grid (with a 4-pt half-step) and a small radius scale.
///
/// Replaces the ad-hoc 1/2/3/4/6/8/10/12/14/18 pt values scattered through
/// the original layout — civic graphic systems favour a strict grid, and a
/// tight scale makes spacing decisions one of: "tight, snug, default,
/// roomy, sectioned." That's it.
public enum ChicagoSpacing {
    public static let xs:  CGFloat = 4
    public static let sm:  CGFloat = 8
    public static let md:  CGFloat = 12
    public static let lg:  CGFloat = 16
    public static let xl:  CGFloat = 24
    public static let xxl: CGFloat = 32

    public enum Radius {
        /// Badges and chips — small sharp civic edge.
        public static let sm: CGFloat = 6
        /// Inline controls, sub-cards.
        public static let md: CGFloat = 8
        /// Full content cards.
        public static let lg: CGFloat = 8
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let thin:     CGFloat = 1
        public static let regular:  CGFloat = 1.5
        public static let bold:     CGFloat = 3
    }
}
