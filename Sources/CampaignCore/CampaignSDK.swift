import Foundation

/// This package's name and version. A connector that fetches sets from a server reports them, so
/// the server can count which versions fetch.
public enum CampaignSDK {
    /// The package name (`swift-app-campaign`).
    public static let name = "swift-app-campaign"
    /// The released version: the newest `## [x.y.z]` section of the CHANGELOG (a test checks it).
    public static let version = "0.7.0"
}
