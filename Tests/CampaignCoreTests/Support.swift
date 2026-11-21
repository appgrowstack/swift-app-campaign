import CampaignCore
import CampaignTesting
import Foundation

typealias TrialOfferPlacement = CampaignTemplate.TrialOffer

/// Registers `trial_offer` with fields that do not match its `Values` (the app's own bug).
struct BrokenPlacement: CampaignPlacement {
    static let name = "trial_offer"
    static let fields: [String: CampaignField] = TrialOfferPlacement.fields
    struct Values: Decodable, Sendable { let headline: Int }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_796_871_600) // 2026-12-10T12:00:00+09:00
    static let id = "trial-2days-after-feature"

    static func campaign(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var campaign: [String: Any] = [
            "schema_version": 1, "id": id, "type": "trial_offer", "status": "active", "title": "2日間を勧める", "purpose": "比べる",
            "priority": 50, "platforms": ["ios", "android"],
            "app_version": ["ios": ">=3.3.0", "android": ">=3.3.0"],
            "starts_at": "2026-12-01T00:00:00+09:00", "ends_at": NSNull(),
            "triggers": [
                ["id": "after_paywall", "event": "paywall_closed",
                 "where": ["prop": "result", "ne": "purchased"], "wait_seconds": 5],
                ["id": "after_exchange", "event": "exchange_completed", "where": NSNull(), "wait_seconds": 600],
            ],
            "audience": ["all": [["fact": "is_premium", "eq": false], ["fact": "trial_eligible", "eq": true]]],
            "limits": ["max_shown": 4, "min_hours_between": 24, "after_dismiss_days": 7, "after_action_days": NSNull()],
            "holdout": 0.2,
            "show": ["placement": "trial_offer", "text_key": "campaign.trial_2days", "values": [
                "headline": ["ja": "プレミアムを2日間、無料で", "en": "Premium free for 2 days"],
                "body": ["ja": "2日間使えます。", "en": "For 2 days."],
                "primary_label": ["ja": "無料で試す", "en": "Try it free"],
                "secondary_label": ["ja": "あとで", "en": "Not now"],
            ]],
            "on_tap": ["action": "start_trial", "args": [String: Any]()],
            "goals": [["event": "purchase_completed", "where": NSNull(), "within_hours": 672]],
        ]
        for (key, value) in overrides { campaign[key] = value }
        return campaign
    }

    static func set(_ campaigns: [[String: Any]] = [campaign()], version: Int = 1, policy: [String: Any] = [:],
                    targets: [String: Any] = [:]) -> Data {
        let set: [String: Any] = [
            "schema_version": 1, "project": "gamification-app", "version": version,
            "published_at": 1_765_000_000_000, "policy": policy, "targets": targets, "campaigns": campaigns,
        ]
        return try! JSONSerialization.data(withJSONObject: set)
    }

    static let paywallClosed = CampaignObservedEvent(name: "paywall_closed", props: ["result": "continue_free", "source": "habit_limit"])

    static func reviewAsk(_ overrides: [String: Any] = [:]) -> [String: Any] {
        campaign([
            "id": "review-after-third-exchange", "type": "review_ask", "holdout": 0, "audience": NSNull(),
            "triggers": [["id": "third_exchange", "event": "exchange_completed",
                          "where": ["prop": "count", "gte": 3], "wait_seconds": 2]],
            "limits": ["max_shown": 3, "max_per_app_version": 1, "min_hours_between": 1440,
                       "after_dismiss_days": 60, "after_action_days": 60],
            "show": ["placement": "review_ask", "values": [String: Any]()],
            "on_tap": ["action": "request_review", "args": [String: Any]()],
        ].merging(overrides) { $1 })
    }

    static func whatsNew() -> [String: Any] {
        campaign([
            "id": "whats-new-3-3-0", "type": "whats_new", "holdout": 0, "audience": NSNull(),
            "triggers": [["id": "updated", "event": "app_updated",
                          "where": ["prop": "to_version", "eq": "3.3.0"], "wait_seconds": 30]],
            "limits": ["max_shown": 1, "min_hours_between": 0, "after_dismiss_days": 0, "after_action_days": NSNull()],
            "show": ["placement": "whats_new", "values": [
                "headline": ["ja": "押さなくても、達成に"], "body": ["ja": "自動で達成になります。"],
            ]],
            "on_tap": ["link": "https://gohobishukan.com/app/settings/auto-check/"],
        ])
    }

    static func crossPromo() -> [String: Any] {
        campaign([
            "id": "cross-promo-reading-memory", "type": "cross_promo", "holdout": 0, "audience": NSNull(),
            "triggers": [["id": "reading_streak", "event": "habit_achieved", "where": NSNull(), "wait_seconds": 0]],
            "show": ["placement": "cross_promo", "values": [
                "headline": ["ja": "読んだ本も、残しませんか"], "body": ["ja": "読書メモリー"],
                "icon": ["asset": "trial_gift"], "primary_label": ["ja": "App Store で見る"],
            ]],
            "on_tap": ["action": "open_store_page", "args": ["target": "reading-memory"]],
        ])
    }

    static let bookAdded = CampaignObservedEvent(name: "book_added")

    static func survey(_ values: [String: Any]? = nil) -> [String: Any] {
        campaign([
            "id": "survey-why-not-premium", "type": "survey", "holdout": 0, "audience": NSNull(),
            "triggers": [["id": "after_book_added", "event": "book_added", "where": NSNull(), "wait_seconds": 0]],
            "limits": ["max_shown": 1, "min_hours_between": 0, "after_dismiss_days": 30, "after_action_days": NSNull()],
            "show": ["placement": "survey", "values": values ?? [
                "question": ["ja": "今は Premium にしない理由は？"],
                "choice_1": ["ja": "値段"], "choice_2": ["ja": "まだ分からない"], "choice_3": ["ja": "ほか"],
                "free_text": true,
            ]],
            "on_tap": ["action": "submit_answer", "args": [String: Any]()],
            "goals": [["event": "survey_answered", "where": NSNull(), "within_hours": 1]],
        ])
    }

    static var readingMemory: [String: Any] { [
        "reading-memory": ["name": "読書メモリー", "ios": ["asc_app_id": "6740000000"]],
    ] }
}

@MainActor
final class Harness {
    let fetcher: FakeCampaignSetFetcher
    let storage: InMemoryCampaignStorage
    let clock: FakeCampaignClock
    let recorder = CampaignEventRecorder()
    let premium = Box(false)
    let eligible = Box<Bool?>(true)
    let busy = Box(false)
    let internalDevice: Box<Bool>
    let person: Box<String>
    let reviews = Box(0)
    let opened = Box<[URL]>([])
    let links = Box<[URL]>([])
    let serverAsks = Box(0)
    let actionRuns = Box<[CampaignActionRequest]>([])
    let engine: CampaignEngine

    init(person: String = "user-6", internalDevice: Bool = false,
         fetcher: FakeCampaignSetFetcher = FakeCampaignSetFetcher(),
         storage: InMemoryCampaignStorage = InMemoryCampaignStorage(),
         clock: FakeCampaignClock = FakeCampaignClock(Fixture.start),
         placements: [any CampaignPlacement.Type] = [TrialOfferPlacement.self],
         appVersion: String = "3.3.0",
         firstSeenAt: Date? = nil,
         actionResult: CampaignActionResult = .completed) {
        self.fetcher = fetcher
        self.storage = storage
        self.clock = clock
        self.internalDevice = Box(internalDevice)
        self.person = Box(person)
        let premium = premium, eligible = eligible, busy = busy, serverAsks = serverAsks, actionRuns = actionRuns
        let internalBox = self.internalDevice, personBox = self.person
        let reviews = reviews, opened = opened, links = links
        engine = CampaignEngine(
            fetcher: fetcher,
            storage: storage,
            context: CampaignContext(appVersion: appVersion, build: "330", channel: "appstore", lang: "ja", region: "JP",
                                     timeZone: TimeZone(identifier: "Asia/Tokyo")!, firstSeenAt: firstSeenAt),
            person: { personBox.value },
            isInternalDevice: { internalBox.value },
            placements: placements,
            facts: [
                .device("is_premium", .bool) { .bool(premium.value) },
                .server("trial_eligible", .bool) {
                    serverAsks.value += 1
                    return eligible.value.map(CampaignValue.bool)
                },
            ],
            actions: [
                .startTrial { request in
                    actionRuns.value.append(request)
                    return actionResult
                },
                .requestReview { reviews.value += 1 },
                .submitAnswer(),
                .openStorePage(providerToken: "118079") { url in
                    opened.value.append(url)
                    return true
                },
            ],
            assets: ["trial_gift"],
            link: { links.value.append($0) },
            record: recorder.record,
            texts: { _ in nil },
            isBusy: { busy.value },
            clock: clock,
            images: FakeImagePrefetcher()
        )
    }

    func load(_ data: Data = Fixture.set(), etag: String = "\"v1\"") async {
        await fetcher.enqueue(.set(data, etag: etag))
        await engine.refresh()
    }

    /// Fetches (304) so the set stays fresh, moves the clock, and sends the event.
    func later(_ seconds: TimeInterval, event: CampaignObservedEvent = Fixture.paywallClosed) async {
        clock.advance(by: seconds)
        await fetcher.enqueue(.notModified)
        await engine.refresh()
        await engine.receive(event)
    }

    func dismissShown() async {
        guard let presentation = engine.presenting else { return }
        await engine.dismiss(presentation, via: .secondary)
    }

    func count(_ name: String) -> Int { recorder.events(named: name).count }
}
