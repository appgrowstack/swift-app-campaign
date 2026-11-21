import Foundation
import Observation

/// Fetches the set, hears events, decides, waits until the screen is free, and hands the app a
/// presentation. Everything it measures goes to `record`; it never sends anything itself.
///
/// - Events that arrive before this launch's first fetch has finished wait for it, so a launch
///   never decides with an old set while a newer one is on its way. When the fetch fails, the set
///   on hand is used while it is younger than the set's `cache_hours`.
/// - After waiting for the screen, the campaign is checked again against the set and counts the
///   device has then (stopped, paused, ended or over a limit: not shown).
/// - The first launch of a newer app version records `app_updated` and decides it as an event
///   (`whats_new`). Do not pass `app_updated` from the app; it is ignored.
@MainActor
@Observable
public final class CampaignEngine: CampaignEventObserving {
    /// The campaign to show now. The app presents its own placement while this is set.
    /// `system` placements never appear here: their action runs at once.
    public private(set) var presenting: CampaignPresentation?
    public var isPresenting: Bool { presenting != nil }
    /// `true` while the app has another full screen up (paywall, onboarding, a celebration…).
    /// Campaigns wait for it to clear, up to the trigger's `wait_seconds`.
    @ObservationIgnored public var isBusy: @MainActor () -> Bool

    @ObservationIgnored public let registry: CampaignRegistry
    @ObservationIgnored public private(set) var set: CampaignSet?

    @ObservationIgnored private let fetcher: any CampaignSetFetching
    @ObservationIgnored private let storage: any CampaignStorage
    @ObservationIgnored private let context: CampaignContext
    @ObservationIgnored private let person: @MainActor () -> String
    @ObservationIgnored private let isInternalDevice: @MainActor () -> Bool
    @ObservationIgnored private let facts: [String: CampaignFact]
    @ObservationIgnored private let actions: [String: CampaignAction]
    @ObservationIgnored private let decoders: [String: @Sendable (CampaignPresentation) -> Bool]
    @ObservationIgnored private let link: @MainActor (URL) -> Void
    @ObservationIgnored private let record: @Sendable (CampaignEvent) -> Void
    @ObservationIgnored private let texts: @Sendable (String) -> String?
    @ObservationIgnored private let clock: any CampaignClock
    @ObservationIgnored private let imageCache: CampaignImageCache
    @ObservationIgnored private let launchedAt: Date

    @ObservationIgnored private var state: CampaignStoredState?
    @ObservationIgnored private var sessionShown = 0
    @ObservationIgnored private var waiting: Waiting?
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var launchFetch: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdate: CampaignObservedEvent?
    /// `paywall_closed` was heard in this launch: `survey` campaigns wait for the next launch.
    @ObservationIgnored private var paywallClosedThisLaunch = false

    private struct Waiting {
        let token: UUID
        let campaign: Campaign
        let trigger: String
    }

    /// - Parameters:
    ///   - fetcher: where the set comes from: ``BundledCampaignSetFetcher`` for the set shipped in the
    ///     app, or a connector that fetches it from a server.
    ///   - person: the person id (R2) — the `person_id` that `identify` answered, or the install id
    ///     until then. Never the uid: a side must not change when the person signs in.
    ///   - isInternalDevice: the owner's or a tester's device (always shown). Read on every decision.
    ///   - facts: cheap device facts first; conditions are read in the order they are written.
    ///   - texts: the app's strings for `<text_key>.<value name>`; `nil` when there is none.
    ///   - record: receives every `campaign_*`, `app_updated` and `link_opened`, for the app's analytics.
    public init(
        fetcher: any CampaignSetFetching,
        storage: any CampaignStorage = .applicationSupport,
        context: CampaignContext,
        person: @escaping @MainActor () -> String,
        isInternalDevice: @escaping @MainActor () -> Bool = { false },
        placements: [any CampaignPlacement.Type],
        facts: [CampaignFact] = [],
        actions: [CampaignAction] = [],
        assets: Set<String> = [],
        link: @escaping @MainActor (URL) -> Void = { _ in },
        record: @escaping @Sendable (CampaignEvent) -> Void,
        texts: @escaping @Sendable (String) -> String? = CampaignEngine.bundleTexts,
        isBusy: @escaping @MainActor () -> Bool = { false },
        clock: any CampaignClock = SystemCampaignClock(),
        images: any CampaignImagePrefetching = URLSessionImagePrefetcher()
    ) {
        self.fetcher = fetcher
        self.storage = storage
        self.context = context
        self.person = person
        self.isInternalDevice = isInternalDevice
        self.facts = Dictionary(facts.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.actions = Dictionary(actions.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.decoders = Dictionary(placements.map { ($0.name, Self.decoder(for: $0)) }, uniquingKeysWith: { _, last in last })
        self.link = link
        self.record = record
        self.texts = texts
        self.isBusy = isBusy
        self.clock = clock
        self.imageCache = CampaignImageCache(images: images)
        self.launchedAt = clock.now
        self.registry = CampaignRegistry(
            placements: placements.map { CampaignPlacementSpec($0) },
            actions: Dictionary(actions.map { ($0.name, $0.arguments) }, uniquingKeysWith: { _, last in last }),
            facts: Dictionary(facts.map { ($0.name, .init(type: $0.type, source: $0.source)) }, uniquingKeysWith: { _, last in last }),
            assets: assets
        )
    }

    /// The app's `Localizable` strings. A key that is missing returns `nil`.
    public nonisolated static let bundleTexts: @Sendable (String) -> String? = { key in
        let text = Bundle.main.localizedString(forKey: key, value: "\u{0}", table: nil)
        return text == "\u{0}" ? nil : text
    }

    private static func decoder(for placement: any CampaignPlacement.Type) -> @Sendable (CampaignPresentation) -> Bool {
        func check<P: CampaignPlacement>(_: P.Type) -> @Sendable (CampaignPresentation) -> Bool {
            { (try? $0.values(as: P.Values.self)) != nil }
        }
        return check(placement)
    }

    // MARK: - Fetching

    /// Fetches the set. Call at launch and on return to the foreground. Failures keep the set on
    /// hand. Calls made while a fetch runs wait for that fetch.
    public func refresh() async {
        await prepare()
        if let refreshing { return await refreshing.value }
        let task = Task { @MainActor in await self.fetchOnce() }
        refreshing = task
        if launchFetch == nil { launchFetch = task }
        await task.value
        refreshing = nil
        if let update = pendingUpdate {
            pendingUpdate = nil
            Task { @MainActor in await self.decide(update) }
        }
    }

    private func fetchOnce() async {
        guard let asked = state else { return }
        let result: CampaignFetchResult
        do {
            result = try await fetcher.fetch(etag: set == nil ? nil : asked.etag)
        } catch {
            return
        }
        // Save the new set before reading the state: a decision can run during any await here (refresh on
        // return to the foreground does not hold it), and its history must not be overwritten by an older copy.
        // A set saved without its etag only costs one full fetch next time.
        var read: CampaignSetLoader.Result?
        if case .fetched(let data, _) = result {
            let loaded = CampaignSetLoader.load(data, registry: registry)
            if case .loaded = loaded { await storage.saveSet(data) }
            read = loaded
        }
        guard var state = self.state else { return }
        var fresh: CampaignSet?
        switch (result, read) {
        case (.notModified, _):
            guard set != nil else { return }
            state.fetchedAt = clock.now
        case (.fetched(_, let etag), .loaded(let loaded, let rejections)?):
            for rejection in rejections {
                report(.rejected(rejection.campaign, version: loaded.version, reason: rejection.reason), into: &state)
            }
            set = loaded
            fresh = loaded
            state.etag = etag
            state.fetchedAt = clock.now
            state.staleReportedVersion = nil
        case (.fetched, .unusable(let version, let reason)?):
            report(.rejected("_set", version: version, reason: reason), into: &state)
        case (.fetched, nil):
            return
        }
        self.state = state
        await storage.saveState(state)
        if let fresh { await imageCache.prefetch(fresh) }
    }

    private func prepare() async {
        if state != nil { return }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in
            let stored = await storage.loadState()
            if let data = await storage.loadSet(), case .loaded(let loaded, _) = CampaignSetLoader.load(data, registry: registry) {
                set = loaded
            }
            let start = CampaignLaunch.start(stored: stored, context: context, now: clock.now)
            if let last = start.updatedFrom {
                let current = context.appVersion
                record(.appUpdated(from: last, to: current))
                pendingUpdate = CampaignObservedEvent(name: "app_updated", props: [
                    "from_version": .string(last), "to_version": .string(current),
                ])
            }
            self.state = start.state
            await storage.saveState(start.state)
            if let set { await imageCache.prefetch(set) }
        }
        preparing = task
        await task.value
    }

    // MARK: - Events

    public nonisolated func observe(_ name: String, _ props: [String: CampaignValue]) {
        let event = CampaignObservedEvent(name: name, props: props)
        Task { @MainActor in await self.receive(event) }
    }

    /// The same as ``observe(_:_:)``, awaited: returns after the campaign was shown or skipped.
    public func receive(_ event: CampaignObservedEvent) async {
        guard Self.accepts(event.name) else { return }
        if event.name == "paywall_closed" { paywallClosedThisLaunch = true }
        await prepare()
        if let launchFetch { await launchFetch.value } else { await refresh() }
        await decide(event)
    }

    /// `campaign_*` are the SDK's own; `app_updated` comes from the SDK itself. `survey_*` are answers,
    /// which never trigger anything.
    nonisolated static func accepts(_ name: String) -> Bool {
        !name.hasPrefix("campaign") && !name.hasPrefix("survey_") && name != "app_updated"
    }

    private func decide(_ event: CampaignObservedEvent) async {
        guard let state, let set, state.fetchedAt != nil else { return }
        let now = clock.now
        let internalDevice = isInternalDevice()
        let input = makeInput(set: set, state: state, now: now, event: event, internalDevice: internalDevice)
        let facts = self.facts
        let decision = await CampaignRules.decide(input) { name in
            guard let fact = facts[name] else { return nil }
            return try? await fact.read()
        }

        guard var state = self.state else { return }
        for event in decision.records {
            if event.name == "campaigns_stale" {
                guard state.staleReportedVersion != set.version else { continue }
                state.staleReportedVersion = set.version
                record(event)
            } else {
                report(event, into: &state)
            }
        }
        for eligible in decision.eligible {
            if !internalDevice, state.sides[eligible.campaign] == nil { state.sides[eligible.campaign] = eligible.side }
            if eligible.side == .holdout {
                state.history.campaigns[eligible.campaign, default: CampaignRecord()].count(at: now, appVersion: context.appVersion)
            }
        }
        self.state = state
        await storage.saveState(state)

        guard let selection = decision.shown else { return }
        await waitAndShow(selection, event: event)
    }

    private func makeInput(set: CampaignSet, state: CampaignStoredState, now: Date, event: CampaignObservedEvent,
                           internalDevice: Bool) -> CampaignDecisionInput {
        // After the paywall was closed, a survey is not the next thing in this launch.
        let set = paywallClosedThisLaunch
            ? CampaignSet(project: set.project, version: set.version, policy: set.policy, targets: set.targets,
                          campaigns: set.campaigns.filter { $0.type != .survey })
            : set
        return CampaignDecisionInput(
            set: set, registry: registry, fetchedAt: state.fetchedAt ?? .distantPast, now: now, context: context,
            internalDevice: internalDevice, person: person(),
            daysSinceFirstSeen: Self.days(from: state.firstSeenAt, to: now, in: context.timeZone),
            sessionSeconds: max(0, Int(now.timeIntervalSince(launchedAt))),
            history: state.history, sessionShown: sessionShown, event: event, texts: texts,
            imagesReady: imageCache.ready, sides: state.sides
        )
    }

    /// Sends `campaign_rejected` once per campaign, set version and reason; everything else as is.
    private func report(_ event: CampaignEvent, into state: inout CampaignStoredState) {
        if event.name == "campaign_rejected" {
            let key = ["campaign", "set_version", "reason"].map { event.parameters[$0]?.description ?? "" }.joined(separator: "|")
            guard state.reportedRejections.insert(key).inserted else { return }
        }
        record(event)
    }

    private func waitAndShow(_ selection: CampaignDecision.Selection, event: CampaignObservedEvent) async {
        let campaign = selection.campaign
        if let current = waiting {
            let version = set?.version ?? 0
            if CampaignRules.ranksBefore(campaign, current.campaign) {
                record(.skipped(current.campaign.id, version: version, trigger: current.trigger, reason: .lowerPriority))
            } else {
                record(.skipped(campaign.id, version: version, trigger: selection.trigger, reason: .lowerPriority))
                return
            }
        }
        let token = UUID()
        waiting = Waiting(token: token, campaign: campaign, trigger: selection.trigger)
        let deadline = clock.now.addingTimeInterval(Double(selection.waitSeconds))
        while isBusy() || presenting != nil {
            if clock.now >= deadline {
                if waiting?.token == token {
                    waiting = nil
                    record(.skipped(campaign.id, version: set?.version ?? 0, trigger: selection.trigger, reason: .busy))
                }
                return
            }
            try? await clock.sleep(seconds: 0.25)
            guard waiting?.token == token else { return }
        }
        guard waiting?.token == token else { return }
        waiting = nil

        // C4: the set and the counts may have changed while waiting.
        guard let set, let state else { return }
        let recheck = CampaignRules.recheck(selection, makeInput(
            set: set, state: state, now: clock.now, event: event, internalDevice: isInternalDevice()
        ))
        recheck.records.forEach(record)
        guard let shown = recheck.shown else { return }
        await show(shown, setVersion: set.version, event: event)
    }

    private func show(_ selection: CampaignDecision.Selection, setVersion: Int, event: CampaignObservedEvent) async {
        let campaign = selection.campaign
        let kind = registry.placements[campaign.placement]?.kind ?? .modal
        let presentation = CampaignPresentation(
            id: UUID(), campaign: campaign.id, setVersion: setVersion, trigger: selection.trigger,
            placement: campaign.placement, values: selection.values, event: event, onTap: campaign.onTap
        )
        guard var state else { return }
        if let decodes = decoders[campaign.placement], !decodes(presentation) {
            report(.rejected(campaign.id, version: setVersion, reason: .typeMismatch), into: &state)
            self.state = state
            await storage.saveState(state)
            return
        }

        let now = clock.now
        if kind != .system { presenting = presentation }
        sessionShown += 1
        state.history.campaigns[campaign.id, default: CampaignRecord()].count(at: now, appVersion: context.appVersion)
        state.history.shownAt = state.history.shownAt.filter { now.timeIntervalSince($0) < 2 * 86400 } + [now]
        record(.init(name: "campaign_shown", parameters: [
            "campaign": .string(campaign.id), "set_version": .int(setVersion),
            "trigger": .string(selection.trigger), "placement": .string(campaign.placement),
        ]))
        self.state = state
        await storage.saveState(state)
        if kind == .system { await complete(presentation, tapped: false) }
    }

    // MARK: - Taps

    /// The primary button. Closes the placement, then runs the action or opens the link.
    public func tap(_ presentation: CampaignPresentation) async {
        guard presenting?.id == presentation.id else { return }
        presenting = nil
        await complete(presentation, tapped: true)
    }

    /// Runs the campaign's `on_tap`: after a tap, or at once for a `system` placement (no `campaign_tapped`).
    private func complete(_ presentation: CampaignPresentation, tapped: Bool) async {
        let base: [String: CampaignValue] = [
            "campaign": .string(presentation.campaign), "set_version": .int(presentation.setVersion),
            "trigger": .string(presentation.trigger),
        ]
        let actionName: String
        let result: CampaignActionResult
        var target: CampaignTarget?
        switch presentation.onTap {
        case .link(let url):
            if tapped { record(.init(name: "campaign_tapped", parameters: base.merging(["target": "link"]) { $1 })) }
            link(url)
            actionName = "link"
            result = .completed
        case .action(let name, let arguments):
            if tapped { record(.init(name: "campaign_tapped", parameters: base.merging(["target": "action"]) { $1 })) }
            actionName = name
            if case .string(let id)? = arguments["target"] { target = set?.targets[id] }
            if let action = actions[name] {
                result = await action.run(CampaignActionRequest(
                    campaign: presentation.campaign, setVersion: presentation.setVersion,
                    trigger: presentation.trigger, event: presentation.event, arguments: arguments, target: target
                ))
            } else {
                result = .failed
            }
        }
        record(.init(name: "campaign_action_completed", parameters: base.merging([
            "action": .string(actionName), "result": .string(result.rawValue),
        ]) { $1 }))
        guard result == .completed else { return }
        if actionName == CampaignAction.openStorePageName, let target {
            record(.init(name: "link_opened", parameters: [
                "kind": "store_page", "target": .string(target.id), "campaign": .string(presentation.campaign),
            ]))
        }
        guard var state else { return }
        state.history.campaigns[presentation.campaign, default: CampaignRecord()].actionCompletedAt = clock.now
        self.state = state
        await storage.saveState(state)
    }

    /// A `survey` answer: `choice` is a ``CampaignTemplate/Survey/Values/choices`` id (`choice_1`…, or
    /// `"0"`…`"<scale>"`). Records `survey_answered`, closes the sheet and runs `submit_answer`. An id the
    /// campaign does not have is ignored. Send what was written with the support connector's `sendFeedback`.
    public func answer(_ presentation: CampaignPresentation, choice: String) async {
        guard presenting?.id == presentation.id, Self.isChoice(choice, of: presentation.values) else { return }
        presenting = nil
        record(.init(name: "survey_answered", parameters: [
            "campaign": .string(presentation.campaign), "set_version": .int(presentation.setVersion),
            "choice": .string(choice),
        ]))
        await complete(presentation, tapped: true)
    }

    /// Whether `choice` is one of the campaign's answers.
    nonisolated static func isChoice(_ choice: String, of values: [String: CampaignResolvedValue]) -> Bool {
        if case .int(let scale)? = values["scale"] {
            guard let n = Int(choice), String(n) == choice else { return false }
            return (0...max(0, scale)).contains(n)
        }
        guard choice.hasPrefix("choice_"), let n = Int(choice.dropFirst(7)), (1...6).contains(n) else { return false }
        return values[choice] != nil
    }

    /// Any way of closing without the primary button.
    public func dismiss(_ presentation: CampaignPresentation, via: CampaignDismissal) async {
        guard presenting?.id == presentation.id else { return }
        presenting = nil
        record(.init(name: "campaign_dismissed", parameters: [
            "campaign": .string(presentation.campaign), "set_version": .int(presentation.setVersion),
            "trigger": .string(presentation.trigger), "via": .string(via.rawValue),
        ]))
        guard var state else { return }
        state.history.campaigns[presentation.campaign, default: CampaignRecord()].dismissedAt = clock.now
        self.state = state
        await storage.saveState(state)
    }

    /// The presentation as `P`'s offer, when `P` is the placement being presented.
    public func offer<P: CampaignPlacement>(_ placement: P.Type) -> CampaignOffer<P>? {
        guard let presentation = presenting, presentation.placement == P.name,
              let values = try? presentation.values(as: P.Values.self) else { return nil }
        return CampaignOffer(
            presentation: presentation, values: values,
            tap: { [weak self] in Task { await self?.tap(presentation) } },
            answer: { [weak self] choice in Task { await self?.answer(presentation, choice: choice) } },
            dismiss: { [weak self] via in Task { await self?.dismiss(presentation, via: via) } }
        )
    }

    // MARK: - Debug

    /// Shows one campaign of the set at once, ignoring its triggers, audience, limits and holdout
    /// (a `system` placement runs its action). For the debug screen. Measurements still go to
    /// `record` (the app's `debug` channel keeps them out of the numbers). Returns `false` when its
    /// text or image is not ready.
    @discardableResult
    public func presentForDebug(campaign id: String) async -> Bool {
        await prepare()
        guard let set, let state, let campaign = set.campaigns.first(where: { $0.id == id }) else { return false }
        var input = makeInput(set: set, state: state, now: clock.now, event: CampaignObservedEvent(name: "debug"),
                              internalDevice: true)
        input.history = .init()
        guard case .success(let values) = CampaignRules.resolveValues(campaign, input) else { return false }
        let presentation = CampaignPresentation(
            id: UUID(), campaign: campaign.id, setVersion: set.version, trigger: "debug",
            placement: campaign.placement, values: values, event: input.event, onTap: campaign.onTap
        )
        if registry.placements[campaign.placement]?.kind == .system {
            await complete(presentation, tapped: false)
        } else {
            presenting = presentation
        }
        return true
    }

    // MARK: - Carrying over

    /// Records a dismissal that happened before the SDK, so `after_dismiss_days` carries over
    /// (for example, an earlier "not now" of the same offer built directly into the app).
    public func carryOverDismissal(campaign: String, at date: Date) async {
        await prepare()
        guard var state else { return }
        let current = state.history.campaigns[campaign]?.dismissedAt ?? .distantPast
        guard date > current else { return }
        state.history.campaigns[campaign, default: CampaignRecord()].dismissedAt = date
        self.state = state
        await storage.saveState(state)
    }

    /// The counts on hand (debug screens and tests).
    public var history: CampaignHistory { state?.history ?? .init() }

    /// The holdout sides decided on this device (debug screens and tests).
    public var sides: [String: CampaignSide] { state?.sides ?? [:] }

    static func days(from start: Date, to end: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return max(0, days)
    }
}
