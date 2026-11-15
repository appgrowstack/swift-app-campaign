import CampaignCore
import CampaignTesting
import Foundation
import Testing

@MainActor
struct CampaignManifestTests {
    static let manifest = Bundle.module.url(forResource: "Cases", withExtension: nil)!
        .appending(path: "manifests/gamification-app.json")

    @Test func registryFromTheManifestMatchesItself() throws {
        let manifest = try CampaignManifest(contentsOf: Self.manifest)
        try CampaignManifest.verify(manifest.registry, against: manifest)
    }

    @Test func differencesAreListed() throws {
        let harness = Harness()
        let error = try #require(throws: CampaignManifestMismatch.self) {
            try CampaignManifest.verify(harness.engine.registry, against: Self.manifest)
        }
        #expect(error.differences.contains("placement banner: in the manifest, not registered"))
        #expect(error.differences.contains("action open_habit: in the manifest, not registered"))
        #expect(error.differences.contains("fact has_trial_grant: in the manifest, not registered"))
    }
}
