import Foundation
import SwiftData

public extension ModelContainer {
    /// A model container rooted in the App Group container so both the app and
    /// its widget extension read/write the same SwiftData store.
    static func sharedAppGroup() throws -> ModelContainer {
        let schema = Schema([
            CachedTrainArrival.self,
            CachedBusPrediction.self,
            CachedMetraPrediction.self,
            CachedVehiclePosition.self,
            CachedIntercampusArrival.self,
            CachedEBikeStation.self,
            CachedNearestBike.self,
            CachedNearestFreeBike.self,
            CachedAlert.self,
            CachedBusDetour.self,
        ])
        let groupURL = AppGroup.containerURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let storeURL = groupURL.appendingPathComponent("CozyFox.sqlite")
        let configuration = ModelConfiguration(
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// In-memory container for tests.
    static func ephemeral() throws -> ModelContainer {
        let schema = Schema([
            CachedTrainArrival.self,
            CachedBusPrediction.self,
            CachedMetraPrediction.self,
            CachedVehiclePosition.self,
            CachedIntercampusArrival.self,
            CachedEBikeStation.self,
            CachedNearestBike.self,
            CachedNearestFreeBike.self,
            CachedAlert.self,
            CachedBusDetour.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
