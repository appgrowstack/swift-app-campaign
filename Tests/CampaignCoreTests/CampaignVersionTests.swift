@testable import CampaignCore
import Testing

struct CampaignVersionTests {
    @Test func versions() {
        #expect(CampaignVersion("3.10") == CampaignVersion(major: 3, minor: 10))
        #expect(CampaignVersion("3.3.0")! < CampaignVersion("3.10.0")!)
        #expect(CampaignVersion("3.x") == nil)
        #expect(CampaignVersion("") == nil)
    }

    @Test func ranges() {
        let range = VersionRange(">=3.3.0 <4.0.0")!
        #expect(range.contains(CampaignVersion("3.3.0")!))
        #expect(range.contains(CampaignVersion("3.99.1")!))
        #expect(!range.contains(CampaignVersion("4.0.0")!))
        #expect(!range.contains(CampaignVersion("3.2.9")!))
        #expect(VersionRange(">=3.3") == nil)
        #expect(VersionRange("~>3.3.0") == nil)
        #expect(VersionRange(">=3.3.0  <4.0.0") == nil)
    }
}
