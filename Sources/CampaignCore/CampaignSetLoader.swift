import Foundation

/// Reads a set and checks each campaign against what the app registered. Pure: no clock, no storage.
public enum CampaignSetLoader {
    /// The schema version this SDK reads.
    public static let schemaVersion = 1

    public struct Rejection: Sendable, Equatable {
        /// The campaign's id, `_set` for the whole set, or `_invalid` when the id itself is unreadable.
        public let campaign: String
        public let reason: CampaignRejectReason
    }

    public enum Result: Sendable, Equatable {
        /// The set is usable. `rejections` lists the campaigns that were skipped.
        case loaded(CampaignSet, rejections: [Rejection])
        /// The whole set is unusable; keep the one on hand. `version` is 0 when unreadable.
        case unusable(version: Int, reason: CampaignRejectReason)
    }

    public static func load(_ data: Data, registry: CampaignRegistry) -> Result {
        guard let root = JSONValue.parse(data)?.object else { return .unusable(version: 0, reason: .parseError) }
        let version = root["version"]?.int ?? 0
        guard let schema = root["schema_version"]?.int else { return .unusable(version: version, reason: .invalid) }
        guard schema <= schemaVersion else { return .unusable(version: version, reason: .schemaTooNew) }
        guard let project = root["project"]?.string, let number = root["version"]?.int, number >= 0,
              let items = root["campaigns"]?.array,
              let targets = targetsOf(root["targets"]) else { return .unusable(version: version, reason: .invalid) }

        var campaigns: [Campaign] = []
        var rejections: [Rejection] = []
        var seen: Set<String> = []
        for item in items {
            do throws(CampaignRejection) {
                let campaign = try parseCampaign(item, registry: registry, targets: targets)
                guard seen.insert(campaign.id).inserted else { throw CampaignRejection.invalid }
                campaigns.append(campaign)
            } catch {
                rejections.append(Rejection(campaign: rejectedID(item), reason: error.reason))
            }
        }
        return .loaded(CampaignSet(project: project, version: version, policy: policy(root["policy"]),
                                   targets: targets, campaigns: campaigns), rejections: rejections)
    }

    private static func rejectedID(_ item: JSONValue) -> String {
        guard let id = item.object?["id"]?.string, isCampaignID(id) else { return "_invalid" }
        return id
    }

    /// `nil` when `targets` is missing or not an object. A target without a name is left out.
    private static func targetsOf(_ json: JSONValue?) -> [String: CampaignTarget]? {
        guard let object = json?.object else { return nil }
        var targets: [String: CampaignTarget] = [:]
        for (id, value) in object {
            guard let target = value.object, let name = target["name"]?.string, !name.isEmpty else { continue }
            targets[id] = CampaignTarget(
                id: id, name: name,
                appStoreID: target["ios"]?.object?["asc_app_id"]?.string,
                playPackage: target["android"]?.object?["package"]?.string
            )
        }
        return targets
    }

    private static func policy(_ json: JSONValue?) -> CampaignPolicy {
        let object = json?.object ?? [:]
        let defaults = CampaignPolicy()
        return CampaignPolicy(
            maxPerSession: object["max_per_session"]?.int.flatMap { $0 >= 1 ? $0 : nil } ?? defaults.maxPerSession,
            maxPerDay: object["max_per_day"]?.int.flatMap { $0 >= 1 ? $0 : nil } ?? defaults.maxPerDay,
            cacheHours: object["cache_hours"]?.number.flatMap { $0 > 0 ? $0 : nil } ?? defaults.cacheHours,
            globalHoldout: object["global_holdout"]?.bool ?? false
        )
    }

    static func isCampaignID(_ id: String) -> Bool {
        (3...40).contains(id.count) && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func isName(_ name: String) -> Bool {
        (1...40).contains(name.count) && name.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    // MARK: - One campaign

    private static func parseCampaign(_ json: JSONValue, registry: CampaignRegistry,
                                      targets: [String: CampaignTarget]) throws(CampaignRejection) -> Campaign {
        guard let object = json.object else { throw .invalid }
        guard let schema = object["schema_version"]?.int else { throw .invalid }
        guard schema <= schemaVersion else { throw .init(.schemaTooNew) }

        guard let id = object["id"]?.string, isCampaignID(id),
              let type = object["type"]?.string.flatMap(CampaignType.init(rawValue:)),
              let status = object["status"]?.string, ["active", "paused", "draft"].contains(status),
              let title = object["title"]?.string,
              object["purpose"]?.string != nil,
              let priority = object["priority"]?.int,
              let platforms = object["platforms"]?.array?.compactMap(\.string), !platforms.isEmpty,
              let versionObject = object["app_version"]?.object, !versionObject.isEmpty,
              let goals = object["goals"]?.array, !goals.isEmpty,
              let holdout = object["holdout"]?.number, (0...0.5).contains(holdout)
        else { throw .invalid }

        var appVersion: [String: VersionRange] = [:]
        for (platform, value) in versionObject {
            guard let text = value.string, let range = VersionRange(text) else { throw .invalid }
            appVersion[platform] = range
        }
        let channels = try channelsOf(object["channels"])
        let startsAt = try timestamp(object, "starts_at")
        let endsAt = try timestamp(object, "ends_at")
        let triggers = try triggersOf(object["triggers"], registry: registry)
        let audience = try audienceOf(object["audience"], registry: registry)
        let limits = try limitsOf(object["limits"])
        let (placement, values, textKey) = try showOf(object["show"], registry: registry)
        let onTap = try onTapOf(object["on_tap"], registry: registry, targets: targets)

        return Campaign(
            id: id, type: type, title: title, priority: priority, placement: placement, status: status,
            platforms: platforms, appVersion: appVersion, channels: channels,
            startsAt: startsAt, endsAt: endsAt, triggers: triggers, audience: audience, limits: limits,
            holdout: holdout, values: values, textKey: textKey, onTap: onTap
        )
    }

    private static func channelsOf(_ json: JSONValue?) throws(CampaignRejection) -> [String] {
        guard let json else { return ["appstore", "play"] }
        guard let items = json.array, !items.isEmpty else { throw .invalid }
        let channels = items.compactMap(\.string)
        guard channels.count == items.count else { throw .invalid }
        return channels
    }

    private static func timestamp(_ object: [String: JSONValue], _ key: String) throws(CampaignRejection) -> Date? {
        guard let value = object[key] else { throw .invalid }
        if value.isNull { return nil }
        guard let text = value.string, let date = CampaignTime.parse(text) else { throw .invalid }
        return date
    }

    private static func triggersOf(_ json: JSONValue?, registry: CampaignRegistry) throws(CampaignRejection) -> [CampaignTrigger] {
        guard let items = json?.array, !items.isEmpty else { throw .invalid }
        var triggers: [CampaignTrigger] = []
        for item in items {
            guard let object = item.object, let id = object["id"]?.string, isName(id),
                  let event = object["event"]?.string, !event.isEmpty,
                  let wait = object["wait_seconds"]?.int, (0...600).contains(wait),
                  let whereValue = object["where"] else { throw .invalid }
            let condition = whereValue.isNull
                ? nil : try CampaignCondition.parse(whereValue, subject: .prop, registry: registry)
            triggers.append(CampaignTrigger(id: id, event: event, condition: condition, waitSeconds: wait))
        }
        return triggers
    }

    private static func audienceOf(_ json: JSONValue?, registry: CampaignRegistry) throws(CampaignRejection) -> CampaignCondition? {
        guard let json else { throw .invalid }
        if json.isNull { return nil }
        return try CampaignCondition.parse(json, subject: .fact, registry: registry)
    }

    private static func limitsOf(_ json: JSONValue?) throws(CampaignRejection) -> CampaignLimits {
        guard let object = json?.object,
              let maxShown = object["max_shown"]?.int, (1...20).contains(maxShown),
              let between = object["min_hours_between"]?.number, between >= 0,
              let dismiss = object["after_dismiss_days"]?.number, dismiss >= 0,
              let action = object["after_action_days"] else { throw .invalid }
        var perVersion: Int?
        if let value = object["max_per_app_version"] {
            guard let count = value.int, (1...20).contains(count) else { throw .invalid }
            perVersion = count
        }
        let afterAction: Double?
        if action.isNull { afterAction = nil } else {
            guard let days = action.number, days >= 0 else { throw .invalid }
            afterAction = days
        }
        return CampaignLimits(maxShown: maxShown, maxPerAppVersion: perVersion, minHoursBetween: between, afterDismissDays: dismiss, afterActionDays: afterAction)
    }

    private static func showOf(_ json: JSONValue?, registry: CampaignRegistry)
        throws(CampaignRejection) -> (String, [String: JSONValue], String?) {
        guard let object = json?.object, let name = object["placement"]?.string,
              let values = object["values"]?.object else { throw .invalid }
        let textKey = object["text_key"]?.string
        guard let placement = registry.placements[name] else { throw .init(.unknownPlacement) }
        for key in values.keys where placement.fields[key] == nil { throw .init(.unknownValue) }
        for (key, field) in placement.fields {
            guard let value = values[key] else {
                // C5: with a text_key, a required text may come from the app's table when it is chosen.
                if field.required && !(field.type == .text && textKey != nil) { throw .init(.missingValue) }
                continue
            }
            try check(value, as: field.type, registry: registry)
        }
        return (name, values, textKey)
    }

    private static func check(_ value: JSONValue, as type: CampaignFieldType, registry: CampaignRegistry) throws(CampaignRejection) {
        switch type {
        case .text:
            guard let texts = value.object, !texts.isEmpty,
                  texts.values.allSatisfy({ ($0.string ?? "").isEmpty == false }) else { throw .init(.typeMismatch) }
        case .image:
            guard let image = CampaignImage(json: value) else { throw .init(.typeMismatch) }
            if case .asset(let name) = image, !registry.assets.contains(name) { throw .init(.unknownAsset) }
        case .int: guard value.int != nil else { throw .init(.typeMismatch) }
        case .bool: guard value.bool != nil else { throw .init(.typeMismatch) }
        case .string: guard value.string != nil else { throw .init(.typeMismatch) }
        }
    }

    private static func onTapOf(_ json: JSONValue?, registry: CampaignRegistry,
                                targets: [String: CampaignTarget]) throws(CampaignRejection) -> CampaignTap {
        guard let object = json?.object else { throw .invalid }
        if let link = object["link"] {
            guard object.count == 1, let text = link.string, let url = URL(string: text),
                  url.scheme == "https", url.host != nil else { throw .invalid }
            return .link(url)
        }
        guard object.count == 2, let name = object["action"]?.string,
              let rawArgs = object["args"]?.object else { throw .invalid }
        guard let spec = registry.actions[name] else { throw .init(.unknownAction) }
        var args: [String: CampaignValue] = [:]
        for (key, raw) in rawArgs {
            guard let argument = spec[key] else { throw .init(.unknownValue) }
            guard let value = raw.scalar, matches(value, argument.type) else { throw .init(.typeMismatch) }
            args[key] = value
        }
        for (key, argument) in spec where argument.required && args[key] == nil { throw .init(.missingValue) }
        if name == CampaignAction.openStorePageName {
            guard case .string(let target)? = args["target"], targets[target] != nil else { throw .init(.unknownTarget) }
        }
        return .action(name, args)
    }

    private static func matches(_ value: CampaignValue, _ type: CampaignArgumentType) -> Bool {
        switch (value, type) {
        case (.string, .string), (.int, .int), (.int, .number), (.double, .number), (.bool, .bool): true
        default: false
        }
    }
}
