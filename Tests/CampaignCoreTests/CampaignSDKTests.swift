@testable import CampaignCore
import Foundation
import Testing

struct CampaignSDKTests {
    /// The version a connector reports must be the one released: the newest `## [x.y.z]` section of the CHANGELOG.
    @Test func versionMatchesTheChangelog() throws {
        let changelog = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let released = try #require(text.firstMatch(of: #/\n## \[(\d+\.\d+\.\d+)\]/#))
        #expect(String(released.1) == CampaignSDK.version)
        #expect(CampaignSDK.name == "swift-app-campaign")
    }
}

struct BundledCampaignSetFetcherTests {
    @Test func givesTheSetOnceThenNotModified() async throws {
        let json = Data(#"{"version":1,"campaigns":[]}"#.utf8)
        let bundled = BundledCampaignSetFetcher(data: json)
        let etag = try #require(bundled.etag)
        #expect(BundledCampaignSetFetcher(data: json).etag == etag)
        #expect(BundledCampaignSetFetcher(data: Data("{}".utf8)).etag != etag)
        #expect(try await bundled.fetch(etag: nil) == .fetched(json, etag: etag))
        #expect(try await bundled.fetch(etag: "\"v3\"") == .fetched(json, etag: etag))
        #expect(try await bundled.fetch(etag: etag) == .notModified)
    }

    @Test func aMissingFileThrows() async {
        let missing = BundledCampaignSetFetcher(resource: "no-such-set", bundle: .main)
        #expect(missing.etag == nil)
        await #expect(throws: BundledCampaignSetFetcher.Missing(resource: "no-such-set")) { try await missing.fetch(etag: nil) }
    }
}
