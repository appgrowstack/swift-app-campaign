import Foundation

/// Why a campaign or a whole set could not be used. Sent as `campaign_rejected(reason=…)`.
public enum CampaignRejectReason: String, Sendable, Hashable, Codable {
    case parseError = "parse_error"
    case schemaTooNew = "schema_too_new"
    case invalid
    case unknownPlacement = "unknown_placement"
    case unknownAction = "unknown_action"
    case unknownAsset = "unknown_asset"
    case unknownFact = "unknown_fact"
    case unknownOperator = "unknown_operator"
    case missingValue = "missing_value"
    case unknownValue = "unknown_value"
    case typeMismatch = "type_mismatch"
}

/// One campaign that passed every check against the app's registration.
public struct Campaign: Sendable, Equatable {
    public let id: String
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

/// A set the device can use: the campaigns that passed the checks, in the set's order.
public struct CampaignSet: Sendable, Equatable {
    public let project: String
    public let version: Int
    public let policy: CampaignPolicy
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
