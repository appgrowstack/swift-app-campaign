@testable import CampaignCore
import Foundation
import Testing

/// Captures the requests a `URLSession` sends and answers 304.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Box<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.value.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// `packages/contract` の APPGROWSTACK_CLIENT_PATTERN と同じ
private var clientPattern: Regex<(Substring, Substring, Substring?, Substring?)> { #/^(ios|android)\/\d+\.\d+(\.\d+)?\/[a-z][a-z0-9-]{1,40}\/\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/# }

@Suite(.serialized)
struct CampaignClientHeaderTests {
    @Test func headerFollowsTheContract() {
        let value = CampaignSDK.client(platform: "ios", appVersion: "3.3.0")
        #expect(value == "ios/3.3.0/swift-app-campaign/\(CampaignSDK.version)")
        #expect(value.wholeMatch(of: clientPattern) != nil)
        #expect(CampaignSDK.client(platform: "ios", appVersion: "3.3").wholeMatch(of: clientPattern) != nil)
    }

    @Test func fetcherSendsTheHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        RecordingURLProtocol.requests.value = []
        let fetcher = HTTPCampaignSetFetcher(
            publicKey: "pk_KUdMabcdefghijklmnopqrst",
            client: CampaignSDK.client(platform: "ios", appVersion: "3.3.0"),
            session: session)

        let result = try await fetcher.fetch(etag: "\"v4\"")

        #expect(result == .notModified)
        let request = try #require(RecordingURLProtocol.requests.value.first)
        #expect(request.url?.absoluteString == "https://api.appgrowstack.com/v1/campaigns/sets/pk_KUdMabcdefghijklmnopqrst")
        #expect(request.value(forHTTPHeaderField: "AppGrowStack-Client") == "ios/3.3.0/swift-app-campaign/\(CampaignSDK.version)")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v4\"")
    }

    /// The version sent must be the one released: the newest `## [x.y.z]` section of the CHANGELOG.
    @Test func versionMatchesTheChangelog() throws {
        let changelog = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let released = try #require(text.firstMatch(of: #/\n## \[(\d+\.\d+\.\d+)\]/#))
        #expect(String(released.1) == CampaignSDK.version)
    }
}
