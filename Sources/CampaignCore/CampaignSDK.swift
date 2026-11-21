import Foundation

/// This package's name and version, sent to appgrowstack in the `AppGrowStack-Client` header.
public enum CampaignSDK {
    /// The package name (`swift-app-campaign`).
    public static let name = "swift-app-campaign"
    /// The released version. `scripts/publish-sdk.sh` refuses to publish when this differs from the tag.
    public static let version = "0.2.0"

    /// The `AppGrowStack-Client` header name.
    public static let clientHeader = "AppGrowStack-Client"

    /// `<platform>/<app_version>/<sdk name>/<sdk version>` (`ios/3.3.0/swift-app-campaign/0.2.0`).
    /// Carries nothing that identifies a person; the API only counts which versions fetch the set.
    public static func client(platform: String, appVersion: String) -> String {
        "\(platform)/\(appVersion)/\(name)/\(version)"
    }
}
