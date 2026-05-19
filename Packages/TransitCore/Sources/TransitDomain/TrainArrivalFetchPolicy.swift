import TransitModels

/// Decides how many arrivals to request from the CTA Train Tracker for a
/// station-level (`mapid`) query.
///
/// `ttarrivals.aspx?mapid=…` returns ETAs sorted by predicted arrival time
/// across **every** line and direction the station serves; per-line
/// filtering happens client-side. Without enough headroom, the busiest
/// lines crowd out the rest — e.g. at Clark/Lake the Blue Line subway
/// (1 line) competes for slots with five elevated lines and routinely
/// gets shoved off the response.
public enum TrainArrivalFetchPolicy {
    /// Two arrivals per (line × direction) pair, floored at 12 so
    /// single-line and small multi-line stations keep their old
    /// behavior. Belmont (3 lines × 2 = 6 pairs) lands on the floor;
    /// Clark/Lake (6 × 2 = 12 pairs) scales up to 24.
    public static func maxArrivals(servedLineCount: Int) -> Int {
        max(12, 4 * servedLineCount)
    }
}
