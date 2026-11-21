import CampaignCore
import CampaignTesting
import Foundation
import Testing

@MainActor
struct CampaignEngineTests {
    static let manyPerSession: [String: Any] = ["max_per_session": 10, "max_per_day": 10]

    @Test func showsTypedValuesAndRecordsShown() async throws {
        let harness = Harness()
        await harness.load()
        await harness.engine.receive(Fixture.paywallClosed)

        let offer = try #require(harness.engine.offer(TrialOfferPlacement.self))
        #expect(offer.values.headline == "プレミアムを2日間、無料で")
        #expect(offer.values.primaryLabel == "無料で試す")
        let shown = try #require(harness.recorder.events(named: "campaign_shown").first)
        #expect(shown.parameters == ["campaign": .string(Fixture.id), "set_version": .int(1), "trigger": "after_paywall", "placement": "trial_offer"])
        #expect(harness.recorder.events(named: "campaign_eligible").map(\.stringParameters) == [
            ["campaign": Fixture.id, "set_version": "1", "trigger": "after_paywall", "side": "treatment"],
        ])
        #expect(harness.serverAsks.value == 1)
    }

    @Test func ignoresItsOwnEventsAndEventsBeforeASet() async {
        let harness = Harness()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        await harness.load()
        await harness.engine.receive(CampaignObservedEvent(name: "campaign_dismissed"))
        await harness.engine.receive(CampaignObservedEvent(name: "app_updated", props: ["to_version": "3.3.0"]))
        #expect(harness.recorder.events.isEmpty)
    }

    // MARK: - Launch

    @Test func firstEventOfALaunchWaitsForTheFetch() async {
        let storage = InMemoryCampaignStorage()
        let clock = FakeCampaignClock(Fixture.start)
        let first = Harness(storage: storage, clock: clock)
        await first.load()

        // The next launch: the stored set still has the campaign, the server has stopped it.
        let next = Harness(storage: storage, clock: clock)
        await next.fetcher.enqueue(.set(Fixture.set([], version: 2), etag: "\"v2\""))
        await next.engine.receive(Fixture.paywallClosed)
        #expect(next.engine.presenting == nil)
        #expect(next.engine.set?.version == 2)
        #expect(next.count("campaign_eligible") == 0)
    }

    @Test func firstLaunchOfANewerVersionDecidesAppUpdated() async throws {
        let storage = InMemoryCampaignStorage()
        let clock = FakeCampaignClock(Fixture.start)
        let set = Fixture.set([Fixture.whatsNew()])
        let old = Harness(storage: storage, clock: clock, placements: [CampaignTemplate.WhatsNew.self], appVersion: "3.2.3")
        await old.load(set)
        #expect(old.count("app_updated") == 0)

        let new = Harness(storage: storage, clock: clock, placements: [CampaignTemplate.WhatsNew.self])
        await new.load(set)
        for _ in 0..<50 where new.engine.presenting == nil { await Task.yield() }
        #expect(new.recorder.events(named: "app_updated").map(\.stringParameters) == [["from_version": "3.2.3", "to_version": "3.3.0"]])
        let offer = try #require(new.engine.offer(CampaignTemplate.WhatsNew.self))
        #expect(offer.values.headline == "押さなくても、達成に")
        #expect(offer.values.primaryLabel == nil)

        // The same version again: nothing.
        let again = Harness(storage: storage, clock: clock, placements: [CampaignTemplate.WhatsNew.self])
        await again.load(set)
        #expect(again.count("app_updated") == 0)
    }

    @Test func stateOfAnEarlierSDKCarriesTheHistoryOver() throws {
        let json = #"{"firstSeenAt":1765000000000,"history":{"shownAt":[],"campaigns":{"a-offer":{"shownCount":2}}},"reportedRejections":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(CampaignStoredState.self, from: Data(json.utf8))
        #expect(state.history.campaigns["a-offer"]?.shownCount == 2)
        #expect(state.history.campaigns["a-offer"]?.shownByAppVersion == [:])
        #expect(state.sides.isEmpty)
        #expect(state.lastAppVersion == nil)
    }

    // MARK: - Unknown things, types, broken JSON

    @Test func unknownPlacementIsRejectedOncePerVersion() async {
        let harness = Harness()
        let set = Fixture.set([Fixture.campaign(["show": ["placement": "home_banner", "values": [String: Any]()]])])
        await harness.load(set)
        await harness.load(set)
        await harness.engine.receive(Fixture.paywallClosed)

        #expect(harness.engine.presenting == nil)
        let rejected = harness.recorder.events(named: "campaign_rejected")
        #expect(rejected.map(\.stringParameters) == [["campaign": Fixture.id, "set_version": "1", "reason": "unknown_placement"]])

        await harness.load(Fixture.set([Fixture.campaign(["show": ["placement": "home_banner", "values": [String: Any]()]])], version: 2))
        #expect(harness.count("campaign_rejected") == 2)
    }

    @Test func valueOfTheWrongTypeIsRejected() async {
        let harness = Harness()
        var show = Fixture.campaign()["show"] as! [String: Any]
        var values = show["values"] as! [String: Any]
        values["headline"] = "見出し"
        show["values"] = values
        await harness.load(Fixture.set([Fixture.campaign(["show": show])]))
        #expect(harness.engine.set?.campaigns.isEmpty == true)
        #expect(harness.recorder.events(named: "campaign_rejected").first?.stringParameters["reason"] == "type_mismatch")
    }

    @Test func conditionOfTheWrongTypeDoesNotMatch() async {
        let harness = Harness()
        await harness.load(Fixture.set([Fixture.campaign(["audience": ["fact": "is_premium", "eq": "false"]])]))
        await harness.engine.receive(Fixture.paywallClosed)
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.count("campaign_rejected") == 1)
    }

    @Test func placementTypeThatCannotDecodeIsNotShown() async {
        let harness = Harness(placements: [BrokenPlacement.self])
        await harness.load()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.count("campaign_shown") == 0)
        #expect(harness.recorder.events(named: "campaign_rejected").first?.stringParameters["reason"] == "type_mismatch")
    }

    @Test func brokenSetKeepsTheOneOnHand() async {
        let harness = Harness()
        await harness.load()
        await harness.load(Data("{\"schema_version\": 1, \"campaigns\": [".utf8), etag: "\"v2\"")
        await harness.load(Data("{\"schema_version\": 2, \"version\": 3}".utf8), etag: "\"v3\"")

        #expect(harness.engine.set?.version == 1)
        #expect(harness.recorder.events(named: "campaign_rejected").map(\.stringParameters) == [
            ["campaign": "_set", "set_version": "0", "reason": "parse_error"],
            ["campaign": "_set", "set_version": "3", "reason": "schema_too_new"],
        ])
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting != nil)
    }

    // MARK: - Offline and 72 hours

    @Test func offlineLaunchUsesTheStoredSet() async {
        let storage = InMemoryCampaignStorage()
        let clock = FakeCampaignClock(Fixture.start)
        let first = Harness(storage: storage, clock: clock)
        await first.load()

        clock.advance(by: 3600)
        let next = Harness(storage: storage, clock: clock)
        await next.engine.refresh() // offline
        await next.engine.receive(Fixture.paywallClosed)
        #expect(next.engine.presenting?.campaign == Fixture.id)
        #expect(await next.fetcher.requestedETags == ["\"v1\""])
    }

    @Test func nothingIsShownAfter72HoursWithoutAFetch() async {
        let harness = Harness()
        await harness.load()
        harness.clock.advance(by: 72 * 3600 + 1)
        await harness.engine.refresh() // offline
        await harness.engine.receive(Fixture.paywallClosed)
        await harness.engine.receive(Fixture.paywallClosed)

        #expect(harness.engine.presenting == nil)
        #expect(harness.recorder.events(named: "campaigns_stale").map(\.stringParameters) == [["set_version": "1", "hours": "72"]])

        await harness.fetcher.enqueue(.notModified)
        await harness.engine.refresh()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting != nil)
    }

    // MARK: - Holdout

    static func isHeldOut(_ person: String, _ campaign: String) -> Bool {
        CampaignHash.side(project: "gamification-app", person: person, campaign: campaign, holdout: 0.2, internalDevice: false) == .holdout
    }

    @Test func holdoutSplitsByTheSharedHash() {
        let people = (0..<20_000).map { "person-\($0)" }
        let held = people.filter { Self.isHeldOut($0, Fixture.id) }
        let share = Double(held.count) / Double(people.count)
        #expect(abs(share - 0.2) < 0.01)
        // Independent per campaign: the same people are not held out of every campaign.
        let other = people.filter { Self.isHeldOut($0, "other-offer") }
        #expect(Set(held).intersection(other).count < held.count / 3)
        #expect(Self.isHeldOut("user-1", Fixture.id))
        #expect(CampaignHash.side(project: "gamification-app", person: "user-1", campaign: Fixture.id, holdout: 0, internalDevice: false) == .treatment)
    }

    @Test func heldOutCountsLikeShown() async {
        let harness = Harness(person: "user-1")
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.recorder.events(named: "campaign_eligible").map { $0.parameters["side"] } == ["holdout"])

        await harness.later(3600) // within min_hours_between
        #expect(harness.count("campaign_eligible") == 1)
        await harness.later(24 * 3600)
        #expect(harness.count("campaign_eligible") == 2)
        #expect(harness.engine.history.campaigns[Fixture.id]?.shownCount == 2)
        #expect(harness.engine.history.campaigns[Fixture.id]?.shownByAppVersion == ["3.3.0": 2])
        #expect(harness.count("campaign_held_out") == 0)
    }

    @Test func aSideOnceDecidedStaysWhenThePersonIdChanges() async {
        let harness = Harness(person: "user-1")
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.sides[Fixture.id] == .holdout)

        harness.person.value = "user-6" // would be treatment by the hash
        await harness.later(24 * 3600)
        #expect(harness.engine.presenting == nil)
        #expect(harness.recorder.events(named: "campaign_eligible").map { $0.parameters["side"] } == ["holdout", "holdout"])
    }

    @Test func ownerDeviceIsNeverHeldOut() async {
        let harness = Harness(person: "user-1", internalDevice: true)
        await harness.load()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting != nil)
        #expect(harness.engine.sides.isEmpty)
    }

    @Test func ownerDeviceIsReadOnEveryDecision() async {
        let harness = Harness(person: "user-1")
        await harness.load(Fixture.set([Fixture.campaign(["id": "aaa-offer"])], policy: Self.manyPerSession))
        harness.internalDevice.value = true // turned on in the debug screen after launch
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting?.campaign == "aaa-offer")
    }

    // MARK: - Limits

    @Test func maxShownFour() async {
        let harness = Harness()
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        for _ in 0..<5 {
            await harness.dismissShown()
            await harness.later(7 * 86400)
        }
        #expect(harness.count("campaign_shown") == 4)
        #expect(harness.count("campaign_dismissed") == 4)
    }

    @Test func sevenDaysAfterDismissing() async {
        let harness = Harness()
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        await harness.dismissShown()

        await harness.later(6 * 86400 + 23 * 3600)
        #expect(harness.engine.presenting == nil)
        await harness.later(3600)
        #expect(harness.engine.presenting != nil)
        #expect(harness.recorder.events(named: "campaign_dismissed").first?.stringParameters["via"] == "secondary")
    }

    @Test func carriedOverDismissalCounts() async {
        let harness = Harness()
        await harness.load()
        await harness.engine.carryOverDismissal(campaign: Fixture.id, at: Fixture.start.addingTimeInterval(-86400))
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
    }

    @Test func onePerSession() async {
        let harness = Harness()
        await harness.load(Fixture.set([Fixture.campaign(), Fixture.campaign(["id": "other-offer"])]))
        await harness.engine.receive(Fixture.paywallClosed)
        await harness.dismissShown()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.count("campaign_shown") == 1)
    }

    @Test func serverFactIsNotAskedWhenADeviceFactFails() async {
        let harness = Harness()
        harness.premium.value = true
        await harness.load()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.serverAsks.value == 0)

        harness.premium.value = false
        harness.eligible.value = nil
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.recorder.events(named: "campaign_skipped").first?.stringParameters["reason"] == "fact_unavailable")
    }

    // MARK: - Waiting and taps

    @Test func stoppedWhileWaitingIsNotShown() async {
        let harness = Harness()
        await harness.load()
        harness.busy.value = true
        let busy = harness.busy, fetcher = harness.fetcher, engine = harness.engine
        Task { @MainActor in
            await fetcher.enqueue(.set(Fixture.set([], version: 2), etag: "\"v2\""))
            await engine.refresh()
            busy.value = false
        }
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.recorder.events(named: "campaign_skipped").map(\.stringParameters) == [
            ["campaign": Fixture.id, "set_version": "2", "trigger": "after_paywall", "reason": "withdrawn"],
        ])
    }

    @Test func waitsWhileBusyThenGivesUp() async {
        let harness = Harness()
        await harness.load()
        harness.busy.value = true
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.recorder.events(named: "campaign_skipped").first?.stringParameters["reason"] == "busy")
    }

    @Test func showsOnceTheScreenIsFree() async {
        let harness = Harness()
        await harness.load()
        harness.busy.value = true
        let busy = harness.busy
        Task { @MainActor in
            for _ in 0..<5 { await Task.yield() }
            busy.value = false
        }
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting != nil)
    }

    @Test func tapRunsTheActionWithItsTrigger() async throws {
        let harness = Harness()
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(CampaignObservedEvent(name: "exchange_completed"))
        let presentation = try #require(harness.engine.presenting)
        await harness.engine.tap(presentation)

        #expect(harness.engine.presenting == nil)
        #expect(harness.actionRuns.value.map(\.trigger) == ["after_exchange"])
        #expect(harness.recorder.names == ["campaign_eligible", "campaign_shown", "campaign_tapped", "campaign_action_completed"])
        #expect(harness.recorder.events(named: "campaign_action_completed").first?.stringParameters["result"] == "completed")

        await harness.later(30 * 86400) // after_action_days null: never again
        #expect(harness.engine.presenting == nil)
    }

    @Test func failedActionCanBeOfferedAgain() async throws {
        let harness = Harness(actionResult: .failed)
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        await harness.engine.tap(try #require(harness.engine.presenting))
        await harness.later(24 * 3600)
        #expect(harness.engine.presenting != nil)
    }

    @Test func observingPortFeedsTheEngine() async {
        let harness = Harness()
        await harness.load()
        let port: any CampaignEventObserving = harness.engine
        port.observe("paywall_closed", ["result": "continue_free"])
        for _ in 0..<50 where harness.engine.presenting == nil { await Task.yield() }
        #expect(harness.engine.presenting != nil)
    }

    // MARK: - Types

    @Test func reviewAskRunsTheSystemPromptAtOnce() async {
        let harness = Harness(placements: [CampaignTemplate.ReviewAsk.self])
        await harness.load(Fixture.set([Fixture.reviewAsk()]))
        harness.clock.advance(by: 8 * 86400)
        await harness.later(0, event: CampaignObservedEvent(name: "exchange_completed", props: ["count": 3]))

        #expect(harness.engine.presenting == nil)
        #expect(harness.reviews.value == 1)
        #expect(harness.recorder.names == ["campaign_eligible", "campaign_shown", "campaign_action_completed"])
        #expect(harness.recorder.events(named: "campaign_action_completed").first?.stringParameters["action"] == "request_review")

        // Once per app version.
        await harness.later(61 * 86400, event: CampaignObservedEvent(name: "exchange_completed", props: ["count": 4]))
        #expect(harness.reviews.value == 1)
    }

    @Test func crossPromoOpensTheStorePageOfTheTarget() async throws {
        let harness = Harness(placements: [CampaignTemplate.CrossPromo.self])
        await harness.load(Fixture.set([Fixture.crossPromo()], targets: Fixture.readingMemory))
        await harness.engine.receive(CampaignObservedEvent(name: "habit_achieved"))
        let offer = try #require(harness.engine.offer(CampaignTemplate.CrossPromo.self))
        #expect(offer.values.icon == .asset("trial_gift"))
        await harness.engine.tap(offer.presentation)

        #expect(harness.opened.value.map(\.absoluteString) == [
            "https://apps.apple.com/app/id6740000000?pt=118079&ct=cross-promo-reading-memory&mt=8",
        ])
        #expect(harness.recorder.events(named: "link_opened").map(\.stringParameters) == [
            ["kind": "store_page", "target": "reading-memory", "campaign": "cross-promo-reading-memory"],
        ])
    }

    @Test func crossPromoWithoutItsTargetIsRejected() async {
        let harness = Harness(placements: [CampaignTemplate.CrossPromo.self])
        await harness.load(Fixture.set([Fixture.crossPromo()]))
        #expect(harness.engine.set?.campaigns.isEmpty == true)
        #expect(harness.recorder.events(named: "campaign_rejected").first?.stringParameters["reason"] == "unknown_target")
    }

    @Test func setWithoutTargetsIsUnusable() async {
        let harness = Harness()
        let json = #"{"schema_version":1,"project":"gamification-app","version":3,"published_at":0,"policy":{},"campaigns":[]}"#
        await harness.load(Data(json.utf8))
        #expect(harness.engine.set == nil)
        #expect(harness.recorder.events(named: "campaign_rejected").first?.stringParameters == ["campaign": "_set", "set_version": "3", "reason": "invalid"])
    }

    @Test func emptySetOfVersionZeroLoads() async {
        let harness = Harness()
        await harness.load(Fixture.set([], version: 0))
        #expect(harness.engine.set?.version == 0)
        #expect(harness.recorder.events.isEmpty)
    }

    @Test func typedValuesFromAnyDictionary() {
        let props: [String: Any] = ["count": 3, "ratio": 0.75, "first_time": true, "source": "widget",
                                    "boxed": NSNumber(value: 5), "flag": NSNumber(value: false), "date": Date()]
        let typed = props.compactMapValues(CampaignValue.init(any:))
        #expect(typed == ["count": .int(3), "ratio": .double(0.75), "first_time": .bool(true), "source": .string("widget"),
                          "boxed": .int(5), "flag": .bool(false)])
    }

    @Test func debugPresentsIgnoringConditions() async {
        let harness = Harness()
        harness.premium.value = true
        await harness.load()
        #expect(await harness.engine.presentForDebug(campaign: Fixture.id))
        #expect(harness.engine.offer(TrialOfferPlacement.self) != nil)
    }
}
