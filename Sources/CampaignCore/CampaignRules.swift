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
    /// The person is in the product-wide holdout (R10) and is shown no campaign.
    case globalHoldout
    case heldOut
    case lowerPriority
    case missingLocale
    case imageNotReady
    /// The screen stayed busy longer than the trigger's `wait_seconds`.
    case busy
    /// The campaign left the set while it waited (C4).
    case withdrawn
    case show

    public enum Inactive: String, Sendable, CaseIterable {
        case status, platform, appVersion = "app_version", channel
        case notStarted = "not_started", ended
    }

    public enum Limit: String, Sendable, CaseIterable {
        case maxShown = "max_shown", maxPerAppVersion = "max_per_app_version"
        case minHoursBetween = "min_hours_between"
        case afterDismiss = "after_dismiss", afterAction = "after_action"
        case notAfterInLaunch = "not_after_in_launch"
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
        case .globalHoldout: "global_holdout"
        case .heldOut: "held_out"
        case .lowerPriority: "lower_priority"
        case .missingLocale: "missing_locale"
        case .imageNotReady: "image_not_ready"
        case .busy: "busy"
        case .withdrawn: "withdrawn"
        case .show: "show"
        }
    }

    public var description: String { code }

    init(_ reason: CampaignSkipReason) {
        switch reason {
        case .busy: self = .busy
        case .lowerPriority: self = .lowerPriority
        case .missingLocale: self = .missingLocale
        case .imageNotReady: self = .imageNotReady
        case .factUnavailable: self = .factUnavailable
        case .withdrawn: self = .withdrawn
        }
    }
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
    /// The owner's or a tester's device: always on the shown side, never remembered.
    public var internalDevice: Bool
    /// The person id (R2: the install id the person was first seen with). Decides the holdout side.
    public var person: String
    public var daysSinceFirstSeen: Int
    /// Seconds since this launch (`session_seconds`).
    public var sessionSeconds: Int
    public var history: CampaignHistory
    public var sessionShown: Int
    /// Events heard earlier in this launch, oldest first. The engine keeps only those some campaign's
    /// `not_after_in_launch` matches (``CampaignRules/remembersInLaunch(_:_:)``).
    public var launchEvents: [CampaignObservedEvent]
    public var event: CampaignObservedEvent
    /// The app's strings table: `<text_key>.<value name>` → text in the app's language.
    public var texts: @Sendable (String) -> String?
    public var imagesReady: Set<URL>
    /// Sides already decided on this device. A side, once decided, does not change.
    public var sides: [String: CampaignSide]

    public init(set: CampaignSet, registry: CampaignRegistry, fetchedAt: Date, now: Date, context: CampaignContext,
                internalDevice: Bool = false, person: String, daysSinceFirstSeen: Int, sessionSeconds: Int = 0,
                history: CampaignHistory, sessionShown: Int, launchEvents: [CampaignObservedEvent] = [],
                event: CampaignObservedEvent,
                texts: @escaping @Sendable (String) -> String? = { _ in nil },
                imagesReady: Set<URL> = [], sides: [String: CampaignSide] = [:]) {
        self.set = set
        self.registry = registry
        self.fetchedAt = fetchedAt
        self.now = now
        self.context = context
        self.internalDevice = internalDevice
        self.person = person
        self.daysSinceFirstSeen = daysSinceFirstSeen
        self.sessionSeconds = sessionSeconds
        self.history = history
        self.sessionShown = sessionShown
        self.launchEvents = launchEvents
        self.event = event
        self.texts = texts
        self.imagesReady = imagesReady
        self.sides = sides
    }
}

public struct CampaignDecision: Sendable {
    public struct Selection: Sendable {
        public let campaign: Campaign
        public let trigger: String
        public let waitSeconds: Int
        public let values: [String: CampaignResolvedValue]
        /// The variant's id (R10 P5), or `nil` for a campaign without variants. Sent as `variant` on
        /// `campaign_shown`, `campaign_tapped`, `campaign_dismissed` and `campaign_action_completed`.
        public let variant: String?
    }

    public struct Eligible: Sendable, Equatable {
        public let campaign: String
        public let trigger: String
        public let side: CampaignSide
        /// The variant chosen on the shown side; `nil` for a campaign without variants and for the holdout side.
        public let variant: String?
    }

    /// The campaign to show, or `nil`.
    public var shown: Selection?
    /// Every campaign in the set that was looked at.
    public var outcomes: [String: CampaignOutcome]
    /// Measurements this decision produced (eligible, skipped, type mismatches, stale).
    public var records: [CampaignEvent]
    /// The server facts that were asked for, in order.
    public var serverFactsRead: [String]
    /// Every campaign that passed step 8, with its side. Held-out ones count as shown.
    public var eligible: [Eligible]
}

/// What the check after waiting (C4) found.
public struct CampaignRecheck: Sendable {
    /// `.show`, or why the campaign is no longer shown (`withdrawn`, `inactive:…`, `limited:…`, …).
    public var outcome: CampaignOutcome
    /// The campaign as it is in the set now, with its values, when it is still to be shown.
    public var shown: CampaignDecision.Selection?
    public var records: [CampaignEvent]
}

/// The decision, as one function: which campaign to show for an event, or why none.
public enum CampaignRules {
    /// - Parameter facts: reads a fact by name; `nil` means "not available". Called lazily: server
    ///   facts only for campaigns whose every device condition has passed, each name at most once.
    public static func decide(_ input: CampaignDecisionInput,
                              facts: @escaping @Sendable (String) async -> CampaignValue?) async -> CampaignDecision {
        var decision = CampaignDecision(shown: nil, outcomes: [:], records: [], serverFactsRead: [], eligible: [])
        let set = input.set
        let version = set.version

        // 1. The set is fresh enough.
        let age = input.now.timeIntervalSince(input.fetchedAt)
        if age > set.policy.cacheHours * 3600 {
            for campaign in set.campaigns { decision.outcomes[campaign.id] = .stale }
            decision.records.append(.stale(version: version, hours: Int(age / 3600)))
            return decision
        }

        let reader = FactReader(input: input, read: facts)
        // The product-wide holdout (R10), when the set applies it. The owner's device is always shown.
        let inGlobalHoldout = set.policy.globalHoldout && !input.internalDevice
            && CampaignHash.globalUnit(project: set.project, person: input.person) < CampaignHash.globalHoldout
        var candidates: [(Campaign, CampaignTrigger, CampaignVariant?)] = []

        for campaign in set.campaigns {
            // 3. Active for this build, now.
            if let inactive = inactive(campaign, input) {
                decision.outcomes[campaign.id] = .inactive(inactive)
                continue
            }
            // 4. The trigger.
            var props = Evaluator(props: input.event.props, reader: nil)
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
            // 5. Limits.
            if let limit = limit(campaign, input) {
                decision.outcomes[campaign.id] = .limited(limit)
                continue
            }
            // 6–7. Device facts, then server facts.
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
            // 8. The product-wide holdout first: not shown and not recorded as eligible, so the
            // campaign's own counts and SRM stay clean.
            if inGlobalHoldout {
                decision.outcomes[campaign.id] = .globalHoldout
                continue
            }
            // 8. Holdout. Both sides are recorded as eligible, with the chance of that side. On the shown
            // side of a campaign with variants, the variant is chosen too and the chance is the variant's;
            // `policy_version` is then the allocation's.
            let side = side(of: campaign, input)
            let allocation = allocation(of: campaign, in: set)
            var variant: CampaignVariant?
            var propensity: Double = input.internalDevice ? (side == .treatment ? 1 : 0)
                : (side == .holdout ? campaign.holdout : 1 - campaign.holdout)
            if side == .treatment, let allocation, let variants = campaign.variants {
                let index = CampaignHash.variantIndex(project: set.project, person: input.person, campaign: campaign.id,
                                                      weights: allocation.weights, internalDevice: input.internalDevice)
                variant = variants[index]
                if !input.internalDevice {
                    let total = allocation.weights.reduce(0, +)
                    propensity = (1 - campaign.holdout) * Double(allocation.weights[index]) / Double(total)
                }
            }
            decision.records.append(.eligible(campaign.id, version: version, trigger: trigger.id, side: side,
                                              variant: variant?.id, propensity: CampaignHash.round6(propensity),
                                              policyVersion: allocation?.policyVersion ?? version))
            decision.eligible.append(.init(campaign: campaign.id, trigger: trigger.id, side: side, variant: variant?.id))
            if side == .holdout {
                decision.outcomes[campaign.id] = .heldOut
                continue
            }
            candidates.append((campaign, trigger, variant))
        }
        decision.serverFactsRead = await reader.serverRead

        // 9. Priority.
        candidates.sort { ranksBefore($0.0, $1.0) }
        guard let (winner, trigger, variant) = candidates.first else { return decision }
        for (loser, loserTrigger, _) in candidates.dropFirst() {
            decision.outcomes[loser.id] = .lowerPriority
            decision.records.append(.skipped(loser.id, version: version, trigger: loserTrigger.id, reason: .lowerPriority))
        }
        // 10. Text and images (the chosen variant's values over the campaign's).
        switch resolveValues(winner, input, variant: variant) {
        case .success(let values):
            decision.outcomes[winner.id] = .show
            decision.shown = .init(campaign: winner, trigger: trigger.id, waitSeconds: trigger.waitSeconds, values: values,
                                   variant: variant?.id)
        case .failure(let reason):
            decision.outcomes[winner.id] = CampaignOutcome(reason)
            decision.records.append(.skipped(winner.id, version: version, trigger: trigger.id, reason: reason))
        }
        return decision
    }

    /// Step 11': after waiting for the screen, looks again at steps 3–5 with the set and counts the
    /// device has now. A campaign no longer in the set is `withdrawn`, recorded with the new version.
    public static func recheck(_ selection: CampaignDecision.Selection, _ input: CampaignDecisionInput) -> CampaignRecheck {
        let id = selection.campaign.id
        let version = input.set.version
        guard let campaign = input.set.campaigns.first(where: { $0.id == id }) else {
            return .init(outcome: .withdrawn, shown: nil,
                         records: [.skipped(id, version: version, trigger: selection.trigger, reason: .withdrawn)])
        }
        if let inactive = inactive(campaign, input) { return .init(outcome: .inactive(inactive), shown: nil, records: []) }
        if let limit = limit(campaign, input) { return .init(outcome: .limited(limit), shown: nil, records: []) }
        // The variant chosen before waiting stays; it is looked up in the set as it is now.
        let variant = campaign.variants?.first { $0.id == selection.variant }
        switch resolveValues(campaign, input, variant: variant) {
        case .success(let values):
            let wait = campaign.triggers.first { $0.id == selection.trigger }?.waitSeconds ?? selection.waitSeconds
            return .init(outcome: .show, shown: .init(campaign: campaign, trigger: selection.trigger, waitSeconds: wait, values: values,
                                                      variant: variant?.id), records: [])
        case .failure(let reason):
            return .init(outcome: CampaignOutcome(reason), shown: nil,
                         records: [.skipped(id, version: version, trigger: selection.trigger, reason: reason)])
        }
    }

    /// The side of a campaign's holdout: the owner's device is always shown; a side decided earlier
    /// stays; otherwise `hash32("<project>:<person>:<campaign>:holdout") / 2^32 < holdout`.
    static func side(of campaign: Campaign, _ input: CampaignDecisionInput) -> CampaignSide {
        if input.internalDevice { return .treatment }
        if let side = input.sides[campaign.id] { return side }
        return CampaignHash.side(project: input.set.project, person: input.person, campaign: campaign.id,
                                 holdout: campaign.holdout, internalDevice: false)
    }

    /// The campaign's allocation: the set's entry, else equal weights with the set's version. `nil`
    /// for a campaign without variants.
    static func allocation(of campaign: Campaign, in set: CampaignSet) -> CampaignAllocation? {
        guard let variants = campaign.variants else { return nil }
        return set.allocations[campaign.id] ?? CampaignAllocation(weights: variants.map { _ in 1 }, policyVersion: set.version)
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
        if let perVersion = limits.maxPerAppVersion,
           record.shownByAppVersion[input.context.appVersion, default: 0] >= perVersion { return .maxPerAppVersion }
        if let last = record.lastShownAt, now.timeIntervalSince(last) < limits.minHoursBetween * 3600 { return .minHoursBetween }
        if let dismissed = record.dismissedAt, now.timeIntervalSince(dismissed) < limits.afterDismissDays * 86400 { return .afterDismiss }
        if let completed = record.actionCompletedAt {
            guard let days = limits.afterActionDays else { return .afterAction }
            if now.timeIntervalSince(completed) < days * 86400 { return .afterAction }
        }
        if input.launchEvents.contains(where: { matches(limits.notAfterInLaunch, $0) }) { return .notAfterInLaunch }
        if input.sessionShown >= input.set.policy.maxPerSession { return .maxPerSession }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.context.timeZone
        let today = input.history.shownAt.filter { calendar.isDate($0, inSameDayAs: now) }.count
        if today >= input.set.policy.maxPerDay { return .maxPerDay }
        return nil
    }

    /// Whether the engine keeps this event for the rest of the launch: only events some campaign's
    /// `not_after_in_launch` matches, handed to the next decisions as ``CampaignDecisionInput/launchEvents``.
    public static func remembersInLaunch(_ set: CampaignSet, _ event: CampaignObservedEvent) -> Bool {
        set.campaigns.contains { matches($0.limits.notAfterInLaunch, event) }
    }

    /// The event has one of the names, and its props pass that `where`. A type mismatch does not match
    /// (and is not recorded).
    static func matches(_ forms: [CampaignLaunchEvent], _ event: CampaignObservedEvent) -> Bool {
        forms.contains { form in
            guard form.event == event.name else { return false }
            guard let condition = form.condition else { return true }
            return propsMatch(condition, event.props)
        }
    }

    /// `where` on an event's props, without facts (a `where` only has props).
    private static func propsMatch(_ condition: CampaignCondition, _ props: [String: CampaignValue]) -> Bool {
        switch condition {
        case .all(let children): children.allSatisfy { propsMatch($0, props) }
        case .any(let children): children.contains { propsMatch($0, props) }
        case .leaf(.prop(let name), let op): op.matches(props[name].map(CampaignLookup.value) ?? .unavailable) ?? false
        case .leaf(.fact, _): false
        }
    }

    /// With a variant, its values are laid over the campaign's and its `text_key` (when set) is used.
    static func resolveValues(_ campaign: Campaign, _ input: CampaignDecisionInput, variant: CampaignVariant? = nil)
        -> Result<[String: CampaignResolvedValue], CampaignSkipReason> {
        guard let placement = input.registry.placements[campaign.placement] else { return .failure(.missingLocale) }
        let values = variant.map { campaign.values.merging($0.values) { $1 } } ?? campaign.values
        let textKey = variant?.textKey ?? campaign.textKey
        var resolved: [String: CampaignResolvedValue] = [:]
        for (name, field) in placement.fields {
            let raw = values[name]
            switch field.type {
            case .text:
                if let text = pickText(raw?.object, lang: input.context.lang)
                    ?? textKey.flatMap({ input.texts("\($0).\(name)") }) {
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
        case "session_seconds": return .int(input.sessionSeconds)
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
