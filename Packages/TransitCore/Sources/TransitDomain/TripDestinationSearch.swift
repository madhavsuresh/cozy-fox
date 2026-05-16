import Foundation
import MapKit
import TransitModels

/// A sendable summary of an `MKLocalSearchCompletion` so the UI layer never
/// has to handle MapKit reference types across actors. We hold the underlying
/// title/subtitle and let `TripDestinationSearch.resolve(_:)` re-look-up the
/// concrete coordinate via `MKLocalSearch`, which is cheap enough to redo on
/// pick.
public struct DestinationSuggestion: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        // Two completions with the same title/subtitle should collapse — Apple
        // can emit duplicates when an address is matched several ways.
        self.id = "\(title)\n\(subtitle)"
    }
}

/// Outcome of resolving a `DestinationSuggestion` to a real point.
public struct ResolvedDestination: Sendable, Hashable {
    public let title: String
    public let subtitle: String
    public let coordinate: PlannerCoordinate

    public init(title: String, subtitle: String, coordinate: PlannerCoordinate) {
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
    }
}

public enum DestinationSearchError: Error, Sendable, LocalizedError {
    case resolutionFailed(String)
    case noMatch

    public var errorDescription: String? {
        switch self {
        case .resolutionFailed(let message): return message
        case .noMatch: return "We couldn't find that place on the map."
        }
    }
}

/// MainActor wrapper around `MKLocalSearchCompleter`. Each instance exposes an
/// `AsyncStream<[DestinationSuggestion]>` that yields the latest results as
/// the user types. The view stays MainActor and reads the stream on a task;
/// the planner stays Sendable because it never touches this class.
@MainActor
public final class TripDestinationSearch {
    private let completer = MKLocalSearchCompleter()
    private let delegate = Delegate()
    public let updates: AsyncStream<[DestinationSuggestion]>

    public init(region: MKCoordinateRegion) {
        var continuation: AsyncStream<[DestinationSuggestion]>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        delegate.continuation = continuation
        completer.delegate = delegate
        completer.region = region
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Update the live query. Empty strings clear the suggestions list.
    public func setQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // MKLocalSearchCompleter won't fire on empty queries, so push the
            // empty list ourselves.
            delegate.continuation?.yield([])
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    /// Re-resolve a suggestion to an actual coordinate by re-issuing an
    /// `MKLocalSearch` constrained to that title.
    public func resolve(_ suggestion: DestinationSuggestion) async throws -> ResolvedDestination {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = suggestion.title.isEmpty
            ? suggestion.subtitle
            : "\(suggestion.title) \(suggestion.subtitle)"
        request.region = completer.region
        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch {
            throw DestinationSearchError.resolutionFailed(error.localizedDescription)
        }
        guard let item = response.mapItems.first else {
            throw DestinationSearchError.noMatch
        }
        let coord = item.placemark.coordinate
        return ResolvedDestination(
            title: suggestion.title.isEmpty ? (item.name ?? suggestion.subtitle) : suggestion.title,
            subtitle: suggestion.subtitle,
            coordinate: PlannerCoordinate(latitude: coord.latitude, longitude: coord.longitude)
        )
    }

    /// Resolve a free-form typed destination without requiring the user to
    /// choose one of the completer suggestions first.
    public func resolve(query text: String) async throws -> ResolvedDestination {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DestinationSearchError.noMatch
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = completer.region
        let search = MKLocalSearch(request: request)
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch {
            throw DestinationSearchError.resolutionFailed(error.localizedDescription)
        }
        guard let item = response.mapItems.first else {
            throw DestinationSearchError.noMatch
        }
        let coord = item.placemark.coordinate
        return ResolvedDestination(
            title: item.name ?? trimmed,
            subtitle: item.placemark.title ?? "",
            coordinate: PlannerCoordinate(latitude: coord.latitude, longitude: coord.longitude)
        )
    }
}

@MainActor
private final class Delegate: NSObject, MKLocalSearchCompleterDelegate {
    // MapKit guarantees delegate callbacks land on the main queue, so this
    // class can safely be MainActor-isolated alongside its parent.
    var continuation: AsyncStream<[DestinationSuggestion]>.Continuation?

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Read the (non-Sendable) completion list outside the assumeIsolated
        // closure, copy only its Sendable strings into our struct, and only
        // ferry the resulting Sendable array onto the MainActor. The MapKit
        // contract guarantees this callback runs on the main thread.
        let mapped = completer.results.map {
            DestinationSuggestion(title: $0.title, subtitle: $0.subtitle)
        }
        MainActor.assumeIsolated {
            _ = self.continuation?.yield(mapped)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            _ = self.continuation?.yield([])
        }
    }
}
