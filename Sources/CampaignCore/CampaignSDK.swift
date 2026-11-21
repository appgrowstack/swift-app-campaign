import Foundation

/// This package's name and version. A connector that fetches sets from a server reports them, so
/// the server can count which versions fetch.
public enum CampaignSDK {
    /// The package name (`swift-app-campaign`).
    public static let name = "swift-app-campaign"
    /// The released version. `scripts/publish-sdk.sh` refuses to publish when this differs from the tag.
    public static let version = "0.2.0"
}
