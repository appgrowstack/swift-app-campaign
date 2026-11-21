import CampaignCore
import CampaignSwiftUI
import CampaignTesting
import SwiftUI
import Testing

struct BannerPlacement: CampaignPlacement {
    static let name = "banner"
    static let fields: [String: CampaignField] = ["title": .text()]
    struct Values: Decodable, Sendable { let title: String }
}

@MainActor
struct CampaignSwiftUITests {
    @Test func modifierBuildsForEachStyle() {
        let engine = CampaignEngine(
            fetcher: FakeCampaignSetFetcher(), storage: InMemoryCampaignStorage(),
            context: CampaignContext(appVersion: "1.0.0", build: "1", channel: "debug", lang: "ja", region: "JP"),
            person: { "p" }, placements: [BannerPlacement.self], record: { _ in }
        )
        let view = Text("root").campaignPlacement(BannerPlacement.self, in: engine) { offer in
            Button(offer.values.title) { offer.tap() }
        }
        #expect(type(of: view) != Never.self)
        #expect(engine.offer(BannerPlacement.self) == nil)
    }
}
