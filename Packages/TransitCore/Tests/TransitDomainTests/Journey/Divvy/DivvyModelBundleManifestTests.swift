import Foundation
import Testing
@testable import TransitDomain

@Suite("DivvyModelBundleManifest")
struct DivvyModelBundleManifestTests {
    @Test func codableRoundTrip() throws {
        let manifest = DivvyModelBundleManifest(
            schemaVersion: 1,
            city: "Chicago",
            trainedAt: Date(timeIntervalSinceReferenceDate: 0),
            expiresAt: Date(timeIntervalSinceReferenceDate: 86_400 * 30),
            stationCatalogHash: "abc",
            featureSchemaHash: "def",
            artifactRefs: ["pickup_classic.bin", "dock_state.tflite"],
            calibrationSummary: "ECE=0.04"
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(DivvyModelBundleManifest.self, from: data)
        #expect(decoded == manifest)
    }

    @Test func isExpiredAfterExpiresAt() {
        let manifest = DivvyModelBundleManifest(
            schemaVersion: 1,
            city: "Chicago",
            trainedAt: Date(timeIntervalSinceReferenceDate: 0),
            expiresAt: Date(timeIntervalSinceReferenceDate: 100),
            stationCatalogHash: "abc",
            featureSchemaHash: "def"
        )
        #expect(manifest.isExpired(now: Date(timeIntervalSinceReferenceDate: 200)))
        #expect(!manifest.isExpired(now: Date(timeIntervalSinceReferenceDate: 50)))
    }
}
