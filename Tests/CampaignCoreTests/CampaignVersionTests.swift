@testable import CampaignCore
import Testing

struct CampaignVersionTests {
    @Test func versions() {
        #expect(CampaignVersion("3.10") == CampaignVersion(major: 3, minor: 10))
        #expect(CampaignVersion("3.3.0")! < CampaignVersion("3.10.0")!)
        #expect(CampaignVersion("3.x") == nil)
        #expect(CampaignVersion("") == nil)
    }

    @Test func appVersions() {
        #expect(CampaignVersion(appVersion: "3.3") == CampaignVersion(major: 3, minor: 3))
        #expect(CampaignVersion(appVersion: "3.3.0") == CampaignVersion(major: 3, minor: 3))
        #expect(CampaignVersion(appVersion: "3") == nil)
        #expect(CampaignVersion(appVersion: "3.x") == nil)
        #expect(CampaignVersion(appVersion: "3.3.0.1") == nil)
        #expect(CampaignVersion(appVersion: "3..0") == nil)
        #expect(CampaignVersion(appVersion: "+3.3") == nil)
    }

    @Test func ranges() throws {
        let range = try #require(ResolvedVersionRange(.object([
            "min": .string("3.3.0"), "exclude": .array([.string("3.4"), .string("3.5.1")]), "note": .string("ignored"),
        ])))
        #expect(range.contains(CampaignVersion("3.3.0")!))
        #expect(range.contains(CampaignVersion("3.99.1")!))
        #expect(range.contains(CampaignVersion("4.0.0")!))
        #expect(!range.contains(CampaignVersion("3.2.9")!))
        #expect(!range.contains(CampaignVersion("3.4.0")!))
        #expect(!range.contains(CampaignVersion("3.5.1")!))
        #expect(range.contains(CampaignVersion("3.5.0")!))
    }

    @Test func unreadableRanges() {
        #expect(ResolvedVersionRange(.string(">=3.3.0")) == nil)
        #expect(ResolvedVersionRange(.object(["min": .string("3.3.0")])) == nil)
        #expect(ResolvedVersionRange(.object(["min": .string("3"), "exclude": .array([])])) == nil)
        #expect(ResolvedVersionRange(.object(["min": .string("3.3.0"), "exclude": .array([.string("4")])])) == nil)
        #expect(ResolvedVersionRange(.object(["min": .string("3.3.0"), "exclude": .array([.int(4)])])) == nil)
    }

    @Test func platforms() {
        #expect(ResolvedVersionRange.platforms(.object([:])) == [:])
        #expect(ResolvedVersionRange.platforms(nil) == nil)
        #expect(ResolvedVersionRange.platforms(.string(">=3.3.0")) == nil)
        #expect(ResolvedVersionRange.platforms(.object(["ios": .string(">=3.3.0")])) == nil)
        #expect(ResolvedVersionRange.platforms(.object([
            "ios": .object(["min": .string("3.3"), "exclude": .array([])]),
        ])) == ["ios": ResolvedVersionRange(min: CampaignVersion(major: 3, minor: 3))])
    }
}
