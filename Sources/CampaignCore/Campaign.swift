import Foundation

/// Why a campaign or a whole set could not be used. Sent as `campaign_rejected(reason=…)`.
public enum CampaignRejectReason: String, Sendable, Hashable, Codable, CaseIterable {
    case parseError = "parse_error"
    case schemaTooNew = "schema_too_new"
    case invalid
    case unknownPlacement = "unknown_placement"
    case unknownAction = "unknown_action"
    case unknownAsset = "unknown_asset"
    case unknownFact = "unknown_fact"
    case unknownOperator = "unknown_operator"
    /// An `open_store_page` names a product that is not in the set's `targets`.
    case unknownTarget = "unknown_target"
    case missingValue = "missing_value"
    case unknownValue = "unknown_value"
    case typeMismatch = "type_mismatch"
}

/// The campaign's type. Every type but `custom` has a template with a default placement and
/// action (``CampaignTemplate``), and extra checks in `app-growth campaigns check`.
public enum CampaignType: String, Sendable, Hashable, Codable, CaseIterable {
    case trialOffer = "trial_offer"
    case reviewAsk = "review_ask"
    case whatsNew = "whats_new"
    case crossPromo = "cross_promo"
    case custom
}

/// One campaign that passed every check against the app's registration.
public struct Campaign: Sendable, Equatable {
    public let id: String
    public let type: CampaignType
    public let title: String
    public let priority: Int
    public let placement: String
    let status: String
    let platforms: [String]
    let appVersion: [String: VersionRange]
    let channels: [String]
    let startsAt: Date?
    let endsAt: Date?
    let triggers: [CampaignTrigger]
    let audience: CampaignCondition?
    let limits: CampaignLimits
    let holdout: Double
    let values: [String: JSONValue]
    let textKey: String?
    let onTap: CampaignTap
}

struct CampaignTrigger: Sendable, Equatable {
    let id: String
    let event: String
    let condition: CampaignCondition?
    let waitSeconds: Int
}

struct CampaignLimits: Sendable, Equatable {
    let maxShown: Int
    /// `nil`: no limit per app version.
    let maxPerAppVersion: Int?
    let minHoursBetween: Double
    let afterDismissDays: Double
    /// `nil`: never again after the action completed.
    let afterActionDays: Double?
}

enum CampaignTap: Sendable, Equatable {
    case action(String, [String: CampaignValue])
    case link(URL)
}

/// The products' shared rules, from the set's `policy`.
public struct CampaignPolicy: Sendable, Equatable {
    public var maxPerSession: Int
    public var maxPerDay: Int
    public var cacheHours: Double

    public init(maxPerSession: Int = 1, maxPerDay: Int = 1, cacheHours: Double = 72) {
        self.maxPerSession = maxPerSession
        self.maxPerDay = maxPerDay
        self.cacheHours = cacheHours
    }
}

/// A product a `cross_promo` campaign introduces, copied from the registry into the set.
public struct CampaignTarget: Sendable, Equatable, Hashable {
    /// The product's project id (`reading-memory`).
    public let id: String
    public let name: String
    /// The App Store id (`asc_app_id`), when the product is on iOS.
    public let appStoreID: String?
    /// The Play package, when the product is on Android.
    public let playPackage: String?

    public init(id: String, name: String, appStoreID: String? = nil, playPackage: String? = nil) {
        self.id = id
        self.name = name
        self.appStoreID = appStoreID
        self.playPackage = playPackage
    }
}

/// A set the device can use: the campaigns that passed the checks, in the set's order.
public struct CampaignSet: Sendable, Equatable {
    public let project: String
    /// 0 for a project that has not sent anything yet.
    public let version: Int
    public let policy: CampaignPolicy
    public let targets: [String: CampaignTarget]
    public let campaigns: [Campaign]
}

enum CampaignTime {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
