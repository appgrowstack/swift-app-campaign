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

    /// The case manifests: gamification-app has the first four types, reading-memory has `survey`.
    static let manifests = ["gamification-app", "reading-memory"].map {
        Bundle.module.url(forResource: "Cases", withExtension: nil)!.appending(path: "inapp/manifests/\($0).json")
    }

    @Test func templatesAreTheManifestsDefaults() throws {
        let manifests = try Self.manifests.map(CampaignManifest.init(contentsOf:))
        for manifest in manifests { #expect(manifest.templateDifferences.isEmpty, "\(manifest.project)") }
        for type in CampaignType.allCases {
            guard let placement = CampaignTemplate.placement(for: type) else { continue }
            // Each type is declared in one of the case manifests.
            let registry = try #require(manifests.first { $0.placements[placement.name] != nil }, "\(type)").registry
            #expect(registry.placements[placement.name] == CampaignPlacementSpec(placement), "\(type)")
            for (name, args) in CampaignTemplate.actions(for: type) {
                #expect(registry.actions[name] == args, "\(name)")
            }
        }
        #expect(try manifests[0].registry.placements["review_ask"]?.kind == .system)
        #expect(try manifests[1].registry.placements["survey"]?.kind == .sheet)
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
