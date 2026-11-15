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
        #expect(shown.stringParameters == ["campaign": Fixture.id, "set_version": "1", "trigger": "after_paywall", "placement": "trial_offer"])
        #expect(harness.serverAsks.value == 1)
    }

    @Test func ignoresItsOwnEventsAndEventsBeforeASet() async {
        let harness = Harness()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        await harness.load()
        await harness.engine.receive(CampaignTriggerEvent(name: "campaign_dismissed"))
        #expect(harness.recorder.events.isEmpty)
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
        let harness = Harness(placement: BrokenPlacement.self)
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

    @Test func holdoutSplitsByTheSharedHash() {
        let people = (0..<20_000).map { "person-\($0)" }
        let held = people.filter {
            CampaignHash.isHeldOut(project: "gamification-app", person: $0, campaign: Fixture.id, share: 0.2)
        }
        let share = Double(held.count) / Double(people.count)
        #expect(abs(share - 0.2) < 0.01)
        // Independent per campaign: the same people are not held out of every campaign.
        let other = people.filter {
            CampaignHash.isHeldOut(project: "gamification-app", person: $0, campaign: "other-offer", share: 0.2)
        }
        #expect(Set(held).intersection(other).count < held.count / 3)
        #expect(CampaignHash.isHeldOut(project: "gamification-app", person: "user-1", campaign: Fixture.id, share: 0.2))
        #expect(!CampaignHash.isHeldOut(project: "gamification-app", person: "user-1", campaign: Fixture.id, share: 0))
    }

    @Test func heldOutCountsLikeShown() async {
        let harness = Harness(person: "user-1")
        await harness.load(Fixture.set(policy: Self.manyPerSession))
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting == nil)
        #expect(harness.count("campaign_held_out") == 1)

        await harness.later(3600) // within min_hours_between
        #expect(harness.count("campaign_held_out") == 1)
        await harness.later(24 * 3600)
        #expect(harness.count("campaign_held_out") == 2)
        #expect(harness.engine.history.campaigns[Fixture.id]?.shownCount == 2)
    }

    @Test func ownerDeviceIsNeverHeldOut() async {
        let harness = Harness(person: "user-1", internalDevice: true)
        await harness.load()
        await harness.engine.receive(Fixture.paywallClosed)
        #expect(harness.engine.presenting != nil)
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
        await harness.engine.receive(CampaignTriggerEvent(name: "exchange_completed"))
        let presentation = try #require(harness.engine.presenting)
        await harness.engine.tap(presentation)

        #expect(harness.engine.presenting == nil)
        #expect(harness.actionRuns.value.map(\.trigger) == ["after_exchange"])
        #expect(harness.recorder.names == ["campaign_shown", "campaign_tapped", "campaign_action_completed"])
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

    @Test func debugPresentsIgnoringConditions() async {
        let harness = Harness()
        harness.premium.value = true
        await harness.load()
        #expect(await harness.engine.presentForDebug(campaign: Fixture.id))
        #expect(harness.engine.offer(TrialOfferPlacement.self) != nil)
    }
}
