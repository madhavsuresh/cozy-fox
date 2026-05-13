import Foundation

/// Complete catalog of CTA "L" stations, loaded once at startup from a JSON
/// resource bundled with the `TransitModels` target. Source dataset is the
/// City of Chicago Data Portal "List of L Stops" (`8pix-ypme`), collapsed to
/// one entry per `map_id` (the value the CTA Train Tracker API needs).
///
/// To refresh: re-run the fetch + transform that lives in the repo notes and
/// drop the new JSON into `Resources/CTAStations.json`. The CTA station roster
/// changes very rarely (years between additions).
public enum LStationCatalog {
    public static let all: [LStation] = loadBundled()

    private static func loadBundled() -> [LStation] {
        guard
            let url = Bundle.module.url(forResource: "CTAStations", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("CTAStations.json missing from TransitModels bundle")
            return []
        }
        do {
            return try JSONDecoder().decode([LStation].self, from: data)
        } catch {
            assertionFailure("Failed to decode CTAStations.json: \(error)")
            return []
        }
    }
}
