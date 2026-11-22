import Foundation

/// What the SDK knows about the build and the device. The same values as the analytics envelope.
///
/// Whether this is the owner's device is not here: it can change while the app runs (the debug
/// screen), so ``CampaignEngine`` reads its `isInternalDevice` on every decision.
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
    /// When the person first used the app, if the app knew it before this SDK (its own first-launch
    /// date). `days_since_first_seen` counts from the earlier of this and the date the engine stored on
    /// its own first launch. `nil`: the engine's own date only.
    public var firstSeenAt: Date?

    public init(platform: String = "ios", appVersion: String, build: String, channel: String,
                lang: String, region: String, timeZone: TimeZone = .current, firstSeenAt: Date? = nil) {
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.lang = lang
        self.region = region
        self.timeZone = timeZone
        self.firstSeenAt = firstSeenAt
    }
}

/// An event as it arrives from the app's analytics (`ObservedEvent`). Values keep their types:
/// a count is an `.int`, never the string `"3"`.
public struct CampaignObservedEvent: Sendable, Equatable {
    public let name: String
    /// Leave out what has no value; there is no null.
    public let props: [String: CampaignValue]

    public init(name: String, props: [String: CampaignValue] = [:]) {
        self.name = name
        self.props = props
    }
}

/// Which side of a campaign's holdout a person is on.
public enum CampaignSide: String, Sendable, Hashable, Codable {
    /// Shown the campaign.
    case treatment
    /// Held out for comparison: never shown, counted as if shown.
    case holdout
}

/// What happened with one campaign for this person. Held-out turns count as shown.
public struct CampaignRecord: Sendable, Equatable, Codable {
    public var shownCount: Int
    public var lastShownAt: Date?
    /// App version → times shown (held-out turns included), for `max_per_app_version`.
    public var shownByAppVersion: [String: Int]
    public var dismissedAt: Date?
    public var actionCompletedAt: Date?

    public init(shownCount: Int = 0, lastShownAt: Date? = nil, shownByAppVersion: [String: Int] = [:],
                dismissedAt: Date? = nil, actionCompletedAt: Date? = nil) {
        self.shownCount = shownCount
        self.lastShownAt = lastShownAt
        self.shownByAppVersion = shownByAppVersion
        self.dismissedAt = dismissedAt
        self.actionCompletedAt = actionCompletedAt
    }

    enum CodingKeys: String, CodingKey { case shownCount, lastShownAt, shownByAppVersion, dismissedAt, actionCompletedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shownCount = try container.decodeIfPresent(Int.self, forKey: .shownCount) ?? 0
        lastShownAt = try container.decodeIfPresent(Date.self, forKey: .lastShownAt)
        shownByAppVersion = try container.decodeIfPresent([String: Int].self, forKey: .shownByAppVersion) ?? [:]
        dismissedAt = try container.decodeIfPresent(Date.self, forKey: .dismissedAt)
        actionCompletedAt = try container.decodeIfPresent(Date.self, forKey: .actionCompletedAt)
    }

    /// Counts one turn (shown, or held out) at `date` in `appVersion`.
    mutating func count(at date: Date, appVersion: String) {
        shownCount += 1
        lastShownAt = date
        shownByAppVersion[appVersion, default: 0] += 1
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
/// Values keep their types (`set_version` is an `.int`).
public struct CampaignEvent: Sendable, Equatable {
    public let name: String
    public let parameters: [String: CampaignValue]

    public init(name: String, parameters: [String: CampaignValue]) {
        self.name = name
        self.parameters = parameters
    }

    /// For pipelines that can only send strings. Prefer the typed ``parameters``.
    public var stringParameters: [String: String] { parameters.mapValues(\.description) }

    static func rejected(_ campaign: String, version: Int, reason: CampaignRejectReason) -> Self {
        .init(name: "campaign_rejected", parameters: ["campaign": .string(campaign), "set_version": .int(version), "reason": .string(reason.rawValue)])
    }

    static func skipped(_ campaign: String, version: Int, trigger: String, reason: CampaignSkipReason) -> Self {
        .init(name: "campaign_skipped", parameters: ["campaign": .string(campaign), "set_version": .int(version), "trigger": .string(trigger), "reason": .string(reason.rawValue)])
    }

    /// `propensity` is the chance of the side; `policy_version` is the set's version (R10).
    static func eligible(_ campaign: String, version: Int, trigger: String, side: CampaignSide, propensity: Double) -> Self {
        .init(name: "campaign_eligible", parameters: [
            "campaign": .string(campaign), "set_version": .int(version), "trigger": .string(trigger), "side": .string(side.rawValue),
            "propensity": propensity == propensity.rounded() ? .int(Int(propensity)) : .double(propensity),
            "policy_version": .int(version),
        ])
    }

    static func stale(version: Int, hours: Int) -> Self {
        .init(name: "campaigns_stale", parameters: ["set_version": .int(version), "hours": .int(hours)])
    }

    static func appUpdated(from: String, to: String) -> Self {
        .init(name: "app_updated", parameters: ["from_version": .string(from), "to_version": .string(to)])
    }
}

/// Why a campaign that passed every condition on the shown side was not shown.
public enum CampaignSkipReason: String, Sendable, Error, CaseIterable {
    case busy
    case lowerPriority = "lower_priority"
    case missingLocale = "missing_locale"
    case imageNotReady = "image_not_ready"
    case factUnavailable = "fact_unavailable"
    /// The campaign left the set (stopped) while it waited for the screen.
    case withdrawn
}

/// How a placement was closed. The app's view says which, since the SDK has no view.
public enum CampaignDismissal: String, Sendable {
    case secondary
    case closeButton = "close_button"
    case swipeDown = "swipe_down"
    case outside
}
