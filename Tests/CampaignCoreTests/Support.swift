import CampaignCore
import CampaignTesting
import Foundation

struct TrialOfferPlacement: CampaignPlacement {
    static let name = "trial_offer"
    static let fields: [String: CampaignField] = [
        "headline": .text(maxChars: 24), "body": .text(maxChars: 120),
        "primary_label": .text(maxChars: 24), "secondary_label": .text(maxChars: 12),
        "image": .image(),
    ]
    struct Values: Decodable, Sendable {
        let headline: String
        let body: String
        let primaryLabel: String
        let secondaryLabel: String
        let image: CampaignImage?
    }
}

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
            "schema_version": 1, "id": id, "status": "active", "title": "2日間を勧める", "purpose": "比べる",
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

    static func set(_ campaigns: [[String: Any]] = [campaign()], version: Int = 1, policy: [String: Any] = [:]) -> Data {
        let set: [String: Any] = [
            "schema_version": 1, "project": "gamification-app", "version": version,
            "published_at": 1_765_000_000_000, "policy": policy, "campaigns": campaigns,
        ]
        return try! JSONSerialization.data(withJSONObject: set)
    }

    static let paywallClosed = CampaignTriggerEvent(name: "paywall_closed", properties: ["result": "continue_free", "source": "habit_limit"])
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
    let serverAsks = Box(0)
    let actionRuns = Box<[CampaignActionRequest]>([])
    let engine: CampaignEngine

    init(person: String = "user-6", internalDevice: Bool = false,
         fetcher: FakeCampaignSetFetcher = FakeCampaignSetFetcher(),
         storage: InMemoryCampaignStorage = InMemoryCampaignStorage(),
         clock: FakeCampaignClock = FakeCampaignClock(Fixture.start),
         placement: any CampaignPlacement.Type = TrialOfferPlacement.self,
         actionResult: CampaignActionResult = .completed) {
        self.fetcher = fetcher
        self.storage = storage
        self.clock = clock
        let premium = premium, eligible = eligible, busy = busy, serverAsks = serverAsks, actionRuns = actionRuns
        engine = CampaignEngine(
            projectKey: "pk_test",
            fetcher: fetcher,
            storage: storage,
            context: CampaignContext(appVersion: "3.3.0", build: "330", channel: "appstore", lang: "ja", region: "JP",
                                     timeZone: TimeZone(identifier: "Asia/Tokyo")!, internalDevice: internalDevice),
            person: { person },
            placements: [placement],
            facts: [
                .device("is_premium", .bool) { .bool(premium.value) },
                .server("trial_eligible", .bool) {
                    serverAsks.value += 1
                    return eligible.value.map(CampaignValue.bool)
                },
            ],
            actions: [CampaignAction("start_trial") { request in
                actionRuns.value.append(request)
                return actionResult
            }],
            assets: ["trial_gift"],
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
    func later(_ seconds: TimeInterval, event: CampaignTriggerEvent = Fixture.paywallClosed) async {
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
