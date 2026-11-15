import Foundation

/// What the SDK knows about the build and the device. The same values as the analytics envelope.
public struct CampaignContext: Sendable, Equatable {
    public var platform: String
    public var appVersion: String
    public var build: String
    /// `appstore`, `testflight`, `debug` (or `play`, `play_test` on Android).
    public var channel: String
    /// The envelope's `lang` (`ja`, `en`, `zh-Hant`…). Picks the text of a campaign.
    public var lang: String
    public var region: String
    /// Where a day starts and ends, for `max_per_day`.
    public var timeZone: TimeZone
    /// The owner's device: never held out, so campaigns can be checked by eye.
    public var internalDevice: Bool

    public init(platform: String = "ios", appVersion: String, build: String, channel: String,
                lang: String, region: String, timeZone: TimeZone = .current, internalDevice: Bool = false) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.lang = lang
        self.region = region
        self.timeZone = timeZone
        self.internalDevice = internalDevice
    }
}

/// An event as it arrives from the app's analytics.
public struct CampaignTriggerEvent: Sendable, Equatable {
    public let name: String
    public let properties: [String: CampaignValue]

    public init(name: String, properties: [String: CampaignValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}

/// What happened with one campaign for this person. Held-out turns count as shown.
public struct CampaignRecord: Sendable, Equatable, Codable {
    public var shownCount: Int
    public var lastShownAt: Date?
    public var dismissedAt: Date?
    public var actionCompletedAt: Date?

    public init(shownCount: Int = 0, lastShownAt: Date? = nil, dismissedAt: Date? = nil, actionCompletedAt: Date? = nil) {
        self.shownCount = shownCount
        self.lastShownAt = lastShownAt
        self.dismissedAt = dismissedAt
        self.actionCompletedAt = actionCompletedAt
    }
}

/// The counts the limits read.
public struct CampaignHistory: Sendable, Equatable, Codable {
    /// Times anything was actually shown (not held out), across campaigns, for `max_per_day`.
    public var shownAt: [Date]
    public var campaigns: [String: CampaignRecord]

    public init(shownAt: [Date] = [], campaigns: [String: CampaignRecord] = [:]) {
        self.shownAt = shownAt
        self.campaigns = campaigns
    }
}

/// One measurement the SDK hands to the app's analytics. The SDK never sends anything itself.
public struct CampaignEvent: Sendable, Equatable {
    public let name: String
    public let parameters: [String: CampaignValue]

    public init(name: String, parameters: [String: CampaignValue]) {
        self.name = name
        self.parameters = parameters
    }

    /// For pipelines that send every value as a string.
    public var stringParameters: [String: String] { parameters.mapValues(\.description) }

    static func rejected(_ campaign: String, version: Int, reason: CampaignRejectReason) -> Self {
        .init(name: "campaign_rejected", parameters: ["campaign": .string(campaign), "set_version": .int(version), "reason": .string(reason.rawValue)])
    }

    static func skipped(_ campaign: String, version: Int, trigger: String, reason: CampaignSkipReason) -> Self {
        .init(name: "campaign_skipped", parameters: ["campaign": .string(campaign), "set_version": .int(version), "trigger": .string(trigger), "reason": .string(reason.rawValue)])
    }

    static func heldOut(_ campaign: String, version: Int, trigger: String) -> Self {
        .init(name: "campaign_held_out", parameters: ["campaign": .string(campaign), "set_version": .int(version), "trigger": .string(trigger)])
    }

    static func stale(version: Int, hours: Int) -> Self {
        .init(name: "campaigns_stale", parameters: ["set_version": .int(version), "hours": .int(hours)])
    }
}

public enum CampaignSkipReason: String, Sendable, Error {
    case busy
    case lowerPriority = "lower_priority"
    case missingLocale = "missing_locale"
    case imageNotReady = "image_not_ready"
    case factUnavailable = "fact_unavailable"
}

/// How a placement was closed. The app's view says which, since the SDK has no view.
public enum CampaignDismissal: String, Sendable {
    case secondary
    case closeButton = "close_button"
    case swipeDown = "swipe_down"
    case outside
}
