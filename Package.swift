// swift-tools-version: 6.2
import PackageDescription

/// In-app campaigns decided on the device: which placement to show, to whom, after which event,
/// how often, and who is held out for comparison. The app owns every pixel; the campaign JSON only
/// names a placement the app registered and the values to hand it.
///
/// **No external dependencies.** The bridge to an analytics client lives in the app (a few lines).
let package = Package(
    name: "swift-app-campaign",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Decision, limits, holdout, fetching and caching the set, the event port, placement
        // registration and type checks, and the metrics hook. Foundation and Observation only.
        .library(name: "CampaignCore", targets: ["CampaignCore"]),
        // Optional SwiftUI helpers to present a modal placement. No visual design.
        .library(name: "CampaignSwiftUI", targets: ["CampaignSwiftUI"]),
        // Test doubles: a fake fetcher, clock and storage, and a recording sink.
        .library(name: "CampaignTesting", targets: ["CampaignTesting"])
    ],
    targets: [
        .target(name: "CampaignCore"),
        .target(name: "CampaignSwiftUI", dependencies: ["CampaignCore"]),
        .target(name: "CampaignTesting", dependencies: ["CampaignCore"]),

        .testTarget(
            name: "CampaignCoreTests",
            dependencies: ["CampaignCore", "CampaignTesting"],
            resources: [.copy("Cases")]
        ),
        .testTarget(name: "CampaignSwiftUITests", dependencies: ["CampaignSwiftUI", "CampaignTesting"])
    ]
)
