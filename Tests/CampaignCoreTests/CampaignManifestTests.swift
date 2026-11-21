import CampaignCore
import CampaignTesting
import Foundation
import Testing

@MainActor
struct CampaignManifestTests {
    static let manifest = Bundle.module.url(forResource: "Cases", withExtension: nil)!
        .appending(path: "inapp/manifests/gamification-app.json")

    @Test func registryFromTheManifestMatchesItself() throws {
        let manifest = try CampaignManifest(contentsOf: Self.manifest)
        try CampaignManifest.verify(manifest.registry, against: manifest)
    }

    @Test func manifestNamesTheProject() throws {
        #expect(try CampaignManifest(contentsOf: Self.manifest).project == "gamification-app")
    }

    @Test func templatesAreTheManifestsDefaults() throws {
        let manifest = try CampaignManifest(contentsOf: Self.manifest)
        #expect(manifest.templateDifferences.isEmpty)
        let registry = manifest.registry
        for type in CampaignType.allCases {
            guard let placement = CampaignTemplate.placement(for: type) else { continue }
            #expect(registry.placements[placement.name] == CampaignPlacementSpec(placement), "\(type)")
            for (name, args) in CampaignTemplate.actions(for: type) {
                #expect(registry.actions[name] == args, "\(name)")
            }
        }
        #expect(registry.placements["review_ask"]?.kind == .system)
    }

    @Test func aTemplatePlacementThatDiffersIsListed() throws {
        var manifest = try CampaignManifest(contentsOf: Self.manifest)
        manifest.placements["review_ask"]?.kind = "modal"
        #expect(manifest.templateDifferences == ["placement review_ask: differs from the review_ask template"])
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
