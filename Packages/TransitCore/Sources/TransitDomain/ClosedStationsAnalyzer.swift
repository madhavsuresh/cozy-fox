import Foundation
import TransitModels

/// Identifies L stations that are fully closed (platforms unusable) based on
/// CTA service alerts.
///
/// CTA's `alerts.aspx` endpoint doesn't structurally tag impacted stations —
/// only impacted *routes*. The station name lives in `Headline` /
/// `ShortDescription` text. We text-match station names from the catalog
/// against alert headlines, gated by a closure-keyword check and an
/// "exclusion" check that avoids flagging stations that are only partially
/// affected (elevator out, stationhouse closed, auxiliary entrance, etc.).
///
/// Conservative by design — better to miss a real closure than to hide a
/// usable station. The keywords match how CTA actually phrases these alerts
/// (verified against the live feed for State/Lake's 2026–2029 closure).
public enum ClosedStationsAnalyzer {
    /// Map IDs of stations to exclude from "nearby" recommendations.
    public static func closedStationIds(
        from alerts: [ServiceAlert],
        catalog: [LStation] = LStationCatalog.all
    ) -> Set<Int> {
        var closed: Set<Int> = []
        for alert in alerts where flagsAStationClosure(alert) {
            for station in catalog {
                guard headline(alert, mentions: station) else { continue }
                guard linesOverlap(station: station, alert: alert) else { continue }
                closed.insert(station.id)
            }
        }
        return closed
    }

    /// True if the alert headline indicates a *station*-level closure (not
    /// a partial impact such as elevator/escalator or stationhouse-only).
    private static func flagsAStationClosure(_ alert: ServiceAlert) -> Bool {
        let h = alert.headline.lowercased()
        // Must contain a closure phrase that refers to the station as a whole.
        let closureSignal = h.contains("station closure")
            || h.contains("station closed")
            || h.contains("station temporary closure")
            || h.contains("station temporarily closed")
            || h.contains("station bypass")
        guard closureSignal else { return false }

        // Exclude partial-impact phrases.
        let partialOnly = h.contains("elevator")
            || h.contains("escalator")
            || h.contains("stationhouse")  // entrance closed but platforms open
            || h.contains("auxiliary entrance")
        return !partialOnly
    }

    private static func headline(_ alert: ServiceAlert, mentions station: LStation) -> Bool {
        // localizedCaseInsensitiveContains is the simplest robust match for
        // names like "State/Lake" that contain punctuation; the alert's
        // headline includes the same canonical name.
        alert.headline.localizedCaseInsensitiveContains(station.name)
    }

    private static func linesOverlap(station: LStation, alert: ServiceAlert) -> Bool {
        // If the alert didn't enumerate impacted lines we trust the name
        // match alone (rare but possible for system-wide notices).
        guard !alert.impactedLineColors.isEmpty else { return true }
        return !Set(station.servedLines).isDisjoint(with: alert.impactedLineColors)
    }
}
