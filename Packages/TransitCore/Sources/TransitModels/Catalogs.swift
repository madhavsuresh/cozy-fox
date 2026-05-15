import Foundation

/// Coordinator for the bundled JSON catalogs. The catalogs use `static let`
/// initialization, which is lazy and thread-safe — first touch from any
/// thread parses the underlying JSON. Several of the bundled files are
/// large (`MetraCatalog.json` ~7 MB, `CTABusStops.json` ~2 MB), so
/// touching them on the main thread before they're cached can stall the
/// first user-visible interaction.
///
/// `Catalogs.prewarm()` schedules all catalogs for parsing on a low-priority
/// background task so the parse cost is paid before the first refresh
/// or scrolling interaction needs them. Idempotent: re-touching a
/// `static let` after first init is just a property load.
public enum Catalogs {
    /// Touch every bundled catalog on a utility-priority background task so
    /// the JSON decode happens off the main actor before the first
    /// dashboard refresh asks for it. Safe to call multiple times.
    public static func prewarm() {
        Task.detached(priority: .utility) {
            // Heaviest first so the 7 MB Metra parse overlaps with bus + L
            // station parses on parallel cores. Touches both the raw
            // catalog and the precomputed indexes so the first
            // dashboard-side `byRoute` / `byLine` / `byId` lookup is just
            // a property load.
            await withTaskGroup(of: Void.self) { group in
                group.addTask(priority: .utility) {
                    _ = MetraStationCatalog.all
                    _ = MetraStationCatalog.allRouteIds
                }
                group.addTask(priority: .utility) {
                    _ = BusStopCatalog.all
                    _ = BusStopCatalog.allRoutes
                    _ = BusStopCatalog.byRoute
                }
                group.addTask(priority: .utility) {
                    _ = LStationCatalog.all
                    _ = LStationCatalog.byId
                    _ = LStationCatalog.byLine
                }
                group.addTask(priority: .utility) {
                    _ = IntercampusCatalog.all
                }
            }
        }
    }
}
