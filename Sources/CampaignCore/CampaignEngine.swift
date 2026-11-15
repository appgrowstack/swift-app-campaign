import Foundation
import Observation

/// Fetches the set, hears events, decides, waits until the screen is free, and hands the app a
/// presentation. Everything it measures goes to `record`; it never sends anything itself.
@MainActor
@Observable
public final class CampaignEngine: CampaignEventObserving {
    /// The campaign to show now. The app presents its own placement while this is set.
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
    @ObservationIgnored private let facts: [String: CampaignFact]
    @ObservationIgnored private let actions: [String: CampaignAction]
    @ObservationIgnored private let decoders: [String: @Sendable (CampaignPresentation) -> Bool]
    @ObservationIgnored private let link: @MainActor (URL) -> Void
    @ObservationIgnored private let record: @Sendable (CampaignEvent) -> Void
    @ObservationIgnored private let texts: @Sendable (String) -> String?
    @ObservationIgnored private let clock: any CampaignClock
    @ObservationIgnored private let images: any CampaignImagePrefetching

    @ObservationIgnored private var state: CampaignStoredState?
    @ObservationIgnored private var sessionShown = 0
    @ObservationIgnored private var imagesReady: Set<URL> = []
    @ObservationIgnored private var waiting: Waiting?
    @ObservationIgnored private var preparing: Task<Void, Never>?

    private struct Waiting {
        let token: UUID
        let campaign: Campaign
        let trigger: String
    }

    /// - Parameters:
    ///   - projectKey: the project's public key (`pk_…`). Not a secret.
    ///   - endpoint: where sets are fetched from; replace it for staging and tests.
    ///   - fetcher: replaces the HTTP fetcher entirely (tests).
    ///   - person: the signed-in uid, or an install id. Decides the holdout side.
    ///   - facts: cheap device facts first; conditions are read in the order they are written.
    ///   - texts: the app's strings for `<text_key>.<value name>`; `nil` when there is none.
    ///   - record: receives every `campaign_*` measurement, for the app's analytics.
    public init(
        projectKey: String,
        endpoint: URL = HTTPCampaignSetFetcher.defaultEndpoint,
        fetcher: (any CampaignSetFetching)? = nil,
        storage: any CampaignStorage = .applicationSupport,
        context: CampaignContext,
        person: @escaping @MainActor () -> String,
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
        self.fetcher = fetcher ?? HTTPCampaignSetFetcher(projectKey: projectKey, endpoint: endpoint)
        self.storage = storage
        self.context = context
        self.person = person
        self.facts = Dictionary(facts.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.actions = Dictionary(actions.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.decoders = Dictionary(placements.map { ($0.name, Self.decoder(for: $0)) }, uniquingKeysWith: { _, last in last })
        self.link = link
        self.record = record
        self.texts = texts
        self.isBusy = isBusy
        self.clock = clock
        self.images = images
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

    /// Fetches the set. Call at launch and on return to the foreground. Failures keep the set on hand.
    public func refresh() async {
        await prepare()
        guard var state else { return }
        let result: CampaignFetchResult
        do {
            result = try await fetcher.fetch(etag: set == nil ? nil : state.etag)
        } catch {
            return
        }
        switch result {
        case .notModified:
            guard set != nil else { return }
            state.fetchedAt = clock.now
        case .fetched(let data, let etag):
            switch CampaignSetLoader.load(data, registry: registry) {
            case .unusable(let version, let reason):
                report(.rejected("_set", version: version, reason: reason), into: &state)
            case .loaded(let loaded, let rejections):
                for rejection in rejections {
                    report(.rejected(rejection.campaign, version: loaded.version, reason: rejection.reason), into: &state)
                }
                set = loaded
                state.etag = etag
                state.fetchedAt = clock.now
                state.staleReportedVersion = nil
                await storage.saveSet(data)
                await prefetchImages(of: loaded)
            }
        }
        self.state = state
        await storage.saveState(state)
    }

    private func prepare() async {
        if state != nil { return }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in
            let stored = await storage.loadState()
            if let data = await storage.loadSet(), case .loaded(let loaded, _) = CampaignSetLoader.load(data, registry: registry) {
                set = loaded
            }
            state = stored ?? CampaignStoredState(firstSeenAt: clock.now)
            if stored == nil, let state { await storage.saveState(state) }
            if let set { await prefetchImages(of: set) }
        }
        preparing = task
        await task.value
    }

    private func prefetchImages(of set: CampaignSet) async {
        for campaign in set.campaigns {
            for value in campaign.values.values {
                guard let image = CampaignImage(json: value), case .url(let url, _, _) = image,
                      !imagesReady.contains(url) else { continue }
                if await images.prefetch(url) { imagesReady.insert(url) }
            }
        }
    }

    // MARK: - Events

    public nonisolated func observe(_ name: String, _ properties: [String: CampaignValue]) {
        let event = CampaignTriggerEvent(name: name, properties: properties)
        Task { @MainActor in await self.receive(event) }
    }

    /// The same as ``observe(_:_:)``, awaited: returns after the campaign was shown or skipped.
    public func receive(_ event: CampaignTriggerEvent) async {
        guard !event.name.hasPrefix("campaign") else { return }
        await prepare()
        guard var state, let set, let fetchedAt = state.fetchedAt else { return }

        let now = clock.now
        let input = CampaignDecisionInput(
            set: set, registry: registry, fetchedAt: fetchedAt, now: now, context: context,
            person: person(), daysSinceFirstSeen: Self.days(from: state.firstSeenAt, to: now, in: context.timeZone),
            history: state.history, sessionShown: sessionShown, event: event, texts: texts, imagesReady: imagesReady
        )
        let facts = self.facts
        let decision = await CampaignRules.decide(input) { name in
            guard let fact = facts[name] else { return nil }
            return try? await fact.read()
        }

        for event in decision.records {
            if event.name == "campaigns_stale" {
                guard state.staleReportedVersion != set.version else { continue }
                state.staleReportedVersion = set.version
                record(event)
            } else {
                report(event, into: &state)
            }
        }
        for held in decision.heldOut {
            state.history.campaigns[held.campaign, default: CampaignRecord()].shownCount += 1
            state.history.campaigns[held.campaign, default: CampaignRecord()].lastShownAt = now
        }
        self.state = state
        await storage.saveState(state)

        guard let selection = decision.shown else { return }
        await waitAndShow(selection, event: event, setVersion: set.version)
    }

    /// Sends `campaign_rejected` once per campaign, set version and reason; everything else as is.
    private func report(_ event: CampaignEvent, into state: inout CampaignStoredState) {
        if event.name == "campaign_rejected" {
            let key = ["campaign", "set_version", "reason"].map { event.parameters[$0]?.description ?? "" }.joined(separator: "|")
            guard state.reportedRejections.insert(key).inserted else { return }
        }
        record(event)
    }

    private func waitAndShow(_ selection: CampaignDecision.Selection, event: CampaignTriggerEvent, setVersion: Int) async {
        let campaign = selection.campaign
        if let current = waiting {
            if CampaignRules.ranksBefore(campaign, current.campaign) {
                record(.skipped(current.campaign.id, version: setVersion, trigger: current.trigger, reason: .lowerPriority))
            } else {
                record(.skipped(campaign.id, version: setVersion, trigger: selection.trigger, reason: .lowerPriority))
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
                    record(.skipped(campaign.id, version: setVersion, trigger: selection.trigger, reason: .busy))
                }
                return
            }
            try? await clock.sleep(seconds: 0.25)
            guard waiting?.token == token else { return }
        }
        guard waiting?.token == token else { return }
        waiting = nil
        guard var state, sessionShown < (set?.policy.maxPerSession ?? 1) else { return }

        let presentation = CampaignPresentation(
            id: UUID(), campaign: campaign.id, setVersion: setVersion, trigger: selection.trigger,
            placement: campaign.placement, values: selection.values, event: event, onTap: campaign.onTap
        )
        if let decodes = decoders[campaign.placement], !decodes(presentation) {
            report(.rejected(campaign.id, version: setVersion, reason: .typeMismatch), into: &state)
            self.state = state
            await storage.saveState(state)
            return
        }

        let now = clock.now
        presenting = presentation
        sessionShown += 1
        state.history.campaigns[campaign.id, default: CampaignRecord()].shownCount += 1
        state.history.campaigns[campaign.id, default: CampaignRecord()].lastShownAt = now
        state.history.shownAt = state.history.shownAt.filter { now.timeIntervalSince($0) < 2 * 86400 } + [now]
        record(.init(name: "campaign_shown", parameters: [
            "campaign": .string(campaign.id), "set_version": .int(setVersion),
            "trigger": .string(selection.trigger), "placement": .string(campaign.placement),
        ]))
        self.state = state
        await storage.saveState(state)
    }

    // MARK: - Taps

    /// The primary button. Closes the placement, then runs the action or opens the link.
    public func tap(_ presentation: CampaignPresentation) async {
        guard presenting?.id == presentation.id else { return }
        presenting = nil
        let base: [String: CampaignValue] = [
            "campaign": .string(presentation.campaign), "set_version": .int(presentation.setVersion),
            "trigger": .string(presentation.trigger),
        ]
        let actionName: String
        let result: CampaignActionResult
        switch presentation.onTap {
        case .link(let url):
            record(.init(name: "campaign_tapped", parameters: base.merging(["target": "link"]) { $1 }))
            link(url)
            actionName = "link"
            result = .completed
        case .action(let name, let arguments):
            record(.init(name: "campaign_tapped", parameters: base.merging(["target": "action"]) { $1 }))
            actionName = name
            if let action = actions[name] {
                result = await action.run(CampaignActionRequest(
                    campaign: presentation.campaign, setVersion: presentation.setVersion,
                    trigger: presentation.trigger, event: presentation.event, arguments: arguments
                ))
            } else {
                result = .failed
            }
        }
        record(.init(name: "campaign_action_completed", parameters: base.merging([
            "action": .string(actionName), "result": .string(result.rawValue),
        ]) { $1 }))
        guard result == .completed, var state else { return }
        state.history.campaigns[presentation.campaign, default: CampaignRecord()].actionCompletedAt = clock.now
        self.state = state
        await storage.saveState(state)
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
            dismiss: { [weak self] via in Task { await self?.dismiss(presentation, via: via) } }
        )
    }

    // MARK: - Debug

    /// Shows one campaign of the set at once, ignoring its triggers, audience, limits and holdout.
    /// For the debug screen. Measurements still go to `record` (the app's `debug` channel keeps
    /// them out of the numbers). Returns `false` when its text or image is not ready.
    @discardableResult
    public func presentForDebug(campaign id: String) async -> Bool {
        await prepare()
        guard let set, let campaign = set.campaigns.first(where: { $0.id == id }) else { return false }
        let input = CampaignDecisionInput(
            set: set, registry: registry, fetchedAt: clock.now, now: clock.now, context: context, person: person(),
            daysSinceFirstSeen: 0, history: .init(), sessionShown: 0,
            event: CampaignTriggerEvent(name: "debug"), texts: texts, imagesReady: imagesReady
        )
        guard case .success(let values) = CampaignRules.resolveValues(campaign, input) else { return false }
        presenting = CampaignPresentation(
            id: UUID(), campaign: campaign.id, setVersion: set.version, trigger: "debug",
            placement: campaign.placement, values: values, event: input.event, onTap: campaign.onTap
        )
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

    static func days(from start: Date, to end: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return max(0, days)
    }
}
