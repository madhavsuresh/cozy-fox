import Foundation

public struct DivvyModelBundleManifest: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let city: String
    public let trainedAt: Date
    public let expiresAt: Date
    public let stationCatalogHash: String
    public let featureSchemaHash: String
    public let artifactRefs: [String]
    public let calibrationSummary: String?

    public init(
        schemaVersion: Int,
        city: String,
        trainedAt: Date,
        expiresAt: Date,
        stationCatalogHash: String,
        featureSchemaHash: String,
        artifactRefs: [String] = [],
        calibrationSummary: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.city = city
        self.trainedAt = trainedAt
        self.expiresAt = expiresAt
        self.stationCatalogHash = stationCatalogHash
        self.featureSchemaHash = featureSchemaHash
        self.artifactRefs = artifactRefs
        self.calibrationSummary = calibrationSummary
    }

    public func isExpired(now: Date = .now) -> Bool {
        now >= expiresAt
    }
}
