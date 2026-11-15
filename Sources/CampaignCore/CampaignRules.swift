import Foundation

/// The outcome for one campaign. `code` is the string the shared cases use.
public enum CampaignOutcome: Sendable, Equatable, CustomStringConvertible {
    case stale
    case rejected(CampaignRejectReason)
    case inactive(Inactive)
    case noTrigger
    case limited(Limit)
    case audience
    case factUnavailable
    case heldOut
    case lowerPriority
    case missingLocale
    case imageNotReady
    case show

    public enum Inactive: String, Sendable {
        case status, platform, appVersion = "app_version", channel
        case notStarted = "not_started", ended
    }

    public enum Limit: String, Sendable {
        case maxShown = "max_shown", minHoursBetween = "min_hours_between"
        case afterDismiss = "after_dismiss", afterAction = "after_action"
        case maxPerSession = "max_per_session", maxPerDay = "max_per_day"
    }

    public var code: String {
        switch self {
        case .stale: "stale"
        case .rejected(let reason): "rejected:\(reason.rawValue)"
        case .inactive(let what): "inactive:\(what.rawValue)"
        case .noTrigger: "no_trigger"
        case .limited(let what): "limited:\(what.rawValue)"
        case .audience: "audience"
        case .factUnavailable: "fact_unavailable"
        case .heldOut: "held_out"
        case .lowerPriority: "lower_priority"
        case .missingLocale: "missing_locale"
        case .imageNotReady: "image_not_ready"
        case .show: "show"
        }
    }

    public var description: String { code }
}

/// A value handed to a placement, after the language is picked.
public enum CampaignResolvedValue: Sendable, Hashable, Encodable {
    case text(String)
    case image(CampaignImage)
    case int(Int)
    case bool(Bool)
    case string(String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value), .string(let value): try container.encode(value)
        case .image(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// Everything one decision reads. Nothing here reads a clock, storage or the network.
public struct CampaignDecisionInput: Sendable {
    public var set: CampaignSet
    public var registry: CampaignRegistry
    public var fetchedAt: Date
    public var now: Date
    public var context: CampaignContext
    public var person: String
    public var daysSinceFirstSeen: Int
    public var history: CampaignHistory
    public var sessionShown: Int
    public var event: CampaignTriggerEvent
    /// The app's strings table: `<text_key>.<value name>` → text in the app's language.
    public var texts: @Sendable (String) -> String?
    public var imagesReady: Set<URL>

    public init(set: CampaignSet, registry: CampaignRegistry, fetchedAt: Date, now: Date, context: CampaignContext,
                person: String, daysSinceFirstSeen: Int, history: CampaignHistory, sessionShown: Int,
                event: CampaignTriggerEvent, texts: @escaping @Sendable (String) -> String? = { _ in nil },
                imagesReady: Set<URL> = []) {
        self.set = set
        self.registry = registry
        self.fetchedAt = fetchedAt
        self.now = now
        self.context = context
        self.person = person
        self.daysSinceFirstSeen = daysSinceFirstSeen
        self.history = history
        self.sessionShown = sessionShown
        self.event = event
        self.texts = texts
        self.imagesReady = imagesReady
    }
}

public struct CampaignDecision: Sendable {
    public struct Selection: Sendable {
        public let campaign: Campaign
        public let trigger: String
        public let waitSeconds: Int
        public let values: [String: CampaignResolvedValue]
    }

    /// The campaign to show, or `nil`.
    public var shown: Selection?
    /// Every campaign in the set that was looked at.
    public var outcomes: [String: CampaignOutcome]
    /// Measurements this decision produced (held out, skipped, type mismatches, stale).
    public var records: [CampaignEvent]
    /// The server facts that were asked for, in order.
    public var serverFactsRead: [String]
    /// Campaigns that were held out, with their trigger, so the caller can count them.
    public var heldOut: [(campaign: String, trigger: String)]
}

/// The decision, as one function: which campaign to show for an event, or why none.
public enum CampaignRules {
    /// - Parameter facts: reads a fact by name; `nil` means "not available". Called lazily: server
    ///   facts only for campaigns whose every device condition has passed, each name at most once.
    public static func decide(_ input: CampaignDecisionInput,
                              facts: @escaping @Sendable (String) async -> CampaignValue?) async -> CampaignDecision {
        var decision = CampaignDecision(shown: nil, outcomes: [:], records: [], serverFactsRead: [], heldOut: [])
        let set = input.set
        let version = set.version

        let age = input.now.timeIntervalSince(input.fetchedAt)
        if age > set.policy.cacheHours * 3600 {
            for campaign in set.campaigns { decision.outcomes[campaign.id] = .stale }
            decision.records.append(.stale(version: version, hours: Int(age / 3600)))
            return decision
        }

        let reader = FactReader(input: input, read: facts)
        var candidates: [(Campaign, CampaignTrigger)] = []

        for campaign in set.campaigns {
            if let inactive = inactive(campaign, input) {
                decision.outcomes[campaign.id] = .inactive(inactive)
                continue
            }
            var props = Evaluator(props: input.event.properties, reader: nil)
            var matched: CampaignTrigger?
            for trigger in campaign.triggers where trigger.event == input.event.name {
                if let condition = trigger.condition {
                    guard await props.evaluate(condition, phase: .full) == Evaluator.Match.yes else { continue }
                }
                matched = trigger
                break
            }
            if props.mismatch { decision.records.append(.rejected(campaign.id, version: version, reason: .typeMismatch)) }
            guard let trigger = matched else {
                decision.outcomes[campaign.id] = .noTrigger
                continue
            }
            if let limit = limit(campaign, input) {
                decision.outcomes[campaign.id] = .limited(limit)
                continue
            }
            if let audience = campaign.audience {
                var evaluator = Evaluator(props: [:], reader: reader)
                var result = await evaluator.evaluate(audience, phase: .device)
                if result == Evaluator.Match.deferred { result = await evaluator.evaluate(audience, phase: .full) }
                if evaluator.mismatch { decision.records.append(.rejected(campaign.id, version: version, reason: .typeMismatch)) }
                if result != Evaluator.Match.yes {
                    if evaluator.serverUnavailable {
                        decision.outcomes[campaign.id] = .factUnavailable
                        decision.records.append(.skipped(campaign.id, version: version, trigger: trigger.id, reason: .factUnavailable))
                    } else {
                        decision.outcomes[campaign.id] = .audience
                    }
                    continue
                }
            }
            if !input.context.internalDevice,
               CampaignHash.isHeldOut(project: set.project, person: input.person, campaign: campaign.id, share: campaign.holdout) {
                decision.outcomes[campaign.id] = .heldOut
                decision.records.append(.heldOut(campaign.id, version: version, trigger: trigger.id))
                decision.heldOut.append((campaign.id, trigger.id))
                continue
            }
            candidates.append((campaign, trigger))
        }
        decision.serverFactsRead = await reader.serverRead

        candidates.sort { ranksBefore($0.0, $1.0) }
        guard let (winner, trigger) = candidates.first else { return decision }
        for (loser, loserTrigger) in candidates.dropFirst() {
            decision.outcomes[loser.id] = .lowerPriority
            decision.records.append(.skipped(loser.id, version: version, trigger: loserTrigger.id, reason: .lowerPriority))
        }
        switch resolveValues(winner, input) {
        case .success(let values):
            decision.outcomes[winner.id] = .show
            decision.shown = .init(campaign: winner, trigger: trigger.id, waitSeconds: trigger.waitSeconds, values: values)
        case .failure(let reason):
            decision.outcomes[winner.id] = reason == .missingLocale ? .missingLocale : .imageNotReady
            decision.records.append(.skipped(winner.id, version: version, trigger: trigger.id, reason: reason))
        }
        return decision
    }

    /// `priority` high first, then the newer `starts_at` (none counts as oldest), then the id.
    static func ranksBefore(_ lhs: Campaign, _ rhs: Campaign) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        let lhsStart = lhs.startsAt ?? .distantPast
        let rhsStart = rhs.startsAt ?? .distantPast
        if lhsStart != rhsStart { return lhsStart > rhsStart }
        return lhs.id < rhs.id
    }

    private static func inactive(_ campaign: Campaign, _ input: CampaignDecisionInput) -> CampaignOutcome.Inactive? {
        let context = input.context
        guard campaign.status == "active" else { return .status }
        guard campaign.platforms.contains(context.platform) else { return .platform }
        guard let range = campaign.appVersion[context.platform],
              let version = CampaignVersion(context.appVersion), range.contains(version) else { return .appVersion }
        guard campaign.channels.contains(context.channel) else { return .channel }
        if let start = campaign.startsAt, input.now < start { return .notStarted }
        if let end = campaign.endsAt, input.now >= end { return .ended }
        return nil
    }

    private static func limit(_ campaign: Campaign, _ input: CampaignDecisionInput) -> CampaignOutcome.Limit? {
        let record = input.history.campaigns[campaign.id] ?? CampaignRecord()
        let limits = campaign.limits
        let now = input.now
        if record.shownCount >= limits.maxShown { return .maxShown }
        if let last = record.lastShownAt, now.timeIntervalSince(last) < limits.minHoursBetween * 3600 { return .minHoursBetween }
        if let dismissed = record.dismissedAt, now.timeIntervalSince(dismissed) < limits.afterDismissDays * 86400 { return .afterDismiss }
        if let completed = record.actionCompletedAt {
            guard let days = limits.afterActionDays else { return .afterAction }
            if now.timeIntervalSince(completed) < days * 86400 { return .afterAction }
        }
        if input.sessionShown >= input.set.policy.maxPerSession { return .maxPerSession }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.context.timeZone
        let today = input.history.shownAt.filter { calendar.isDate($0, inSameDayAs: now) }.count
        if today >= input.set.policy.maxPerDay { return .maxPerDay }
        return nil
    }

    static func resolveValues(_ campaign: Campaign, _ input: CampaignDecisionInput)
        -> Result<[String: CampaignResolvedValue], CampaignSkipReason> {
        guard let placement = input.registry.placements[campaign.placement] else { return .failure(.missingLocale) }
        var resolved: [String: CampaignResolvedValue] = [:]
        for (name, field) in placement.fields {
            let raw = campaign.values[name]
            switch field.type {
            case .text:
                if let text = pickText(raw?.object, lang: input.context.lang)
                    ?? campaign.textKey.flatMap({ input.texts("\($0).\(name)") }) {
                    resolved[name] = .text(text)
                } else if field.required {
                    return .failure(.missingLocale)
                }
            case .image:
                guard let raw, let image = CampaignImage(json: raw) else { continue }
                if case .url(let url, _, _) = image, !input.imagesReady.contains(url) { return .failure(.imageNotReady) }
                resolved[name] = .image(image)
            case .int: if let value = raw?.int { resolved[name] = .int(value) }
            case .bool: if let value = raw?.bool { resolved[name] = .bool(value) }
            case .string: if let value = raw?.string { resolved[name] = .string(value) }
            }
        }
        return .success(resolved)
    }

    /// The device's language as it is, then its first part (`zh-Hant` → `zh`).
    static func pickText(_ texts: [String: JSONValue]?, lang: String) -> String? {
        guard let texts else { return nil }
        if let text = texts[lang]?.string { return text }
        let base = String(lang.split(separator: "-").first ?? "")
        return base == lang ? nil : texts[base]?.string
    }
}

/// Reads each fact at most once per decision and remembers which server facts were asked for.
private actor FactReader {
    private let input: CampaignDecisionInput
    private let read: @Sendable (String) async -> CampaignValue?
    private var cache: [String: CampaignLookup] = [:]
    private(set) var serverRead: [String] = []

    init(input: CampaignDecisionInput, read: @Sendable @escaping (String) async -> CampaignValue?) {
        self.input = input
        self.read = read
    }

    func source(of name: String) -> CampaignFactSource {
        input.registry.fact(name)?.source ?? .device
    }

    func lookup(_ name: String) async -> CampaignLookup {
        if let cached = cache[name] { return cached }
        let lookup: CampaignLookup
        if let sdk = sdkFact(name) {
            lookup = .value(sdk)
        } else {
            if source(of: name) == .server { serverRead.append(name) }
            lookup = await read(name).map(CampaignLookup.value) ?? .unavailable
        }
        cache[name] = lookup
        return lookup
    }

    private func sdkFact(_ name: String) -> CampaignValue? {
        let context = input.context
        switch name {
        case "platform": return .string(context.platform)
        case "app_version": return .string(context.appVersion)
        case "build": return .string(context.build)
        case "channel": return .string(context.channel)
        case "lang": return .string(context.lang)
        case "region": return .string(context.region)
        case "days_since_first_seen": return .int(input.daysSinceFirstSeen)
        default: return nil
        }
    }
}

/// Evaluates a condition left to right; `all` stops at the first false, `any` at the first true.
private struct Evaluator {
    enum Phase { case device, full }
    enum Match { case yes, no, deferred }

    let props: [String: CampaignValue]
    let reader: FactReader?
    var mismatch = false
    var serverUnavailable = false

    mutating func evaluate(_ condition: CampaignCondition, phase: Phase) async -> Match {
        switch condition {
        case .all(let children):
            var deferred = false
            for child in children {
                switch await evaluate(child, phase: phase) {
                case .no: return .no
                case .deferred: deferred = true
                case .yes: break
                }
            }
            return deferred ? .deferred : .yes
        case .any(let children):
            var deferred = false
            for child in children {
                switch await evaluate(child, phase: phase) {
                case .yes: return .yes
                case .deferred: deferred = true
                case .no: break
                }
            }
            return deferred ? .deferred : .no
        case .leaf(.prop(let name), let op):
            return compare(props[name].map(CampaignLookup.value) ?? .unavailable, op)
        case .leaf(.fact(let name), let op):
            guard let reader else { return .no }
            let isServer = await reader.source(of: name) == .server
            if isServer && phase == .device { return .deferred }
            let lookup = await reader.lookup(name)
            let match = compare(lookup, op)
            if isServer, lookup == .unavailable, match == .no { serverUnavailable = true }
            return match
        }
    }

    private mutating func compare(_ lookup: CampaignLookup, _ op: CampaignCondition.Operator) -> Match {
        guard let result = op.matches(lookup) else {
            mismatch = true
            return .no
        }
        return result ? .yes : .no
    }
}
