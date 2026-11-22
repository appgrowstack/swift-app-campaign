# swift-app-campaign

Show the right thing to the right person inside your app without shipping a new build, with the decision made on the device.

[Japanese](./README.ja.md)

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

A campaign names one of your app's own screens (a placement), the values to fill it with, the event
that triggers it, who it is for, how often, and who is held out for comparison.

## Features

- **Your screens only.** A campaign can show only placements your app registered and that passed
  review in your binary. No HTML, no downloaded UI, no visual design in the SDK
- **Ready-made types.** `trial_offer`, `review_ask` (the system's rating prompt, nothing in front of
  it), `whats_new` and `cross_promo` come with their default placements and actions
  (`CampaignTemplate`)
- **A pure decision with reasons.** `CampaignRules.decide` reads no clock, storage or network and
  returns the campaign to show, or each campaign's reason not to: stale set, unusable, inactive,
  no trigger, limits, device conditions, server conditions, holdout, priority, text and images
- **Checked again after waiting.** A campaign waits while another full screen is up; then the set
  and the counts are read again, so a campaign stopped, paused or ended meanwhile is not shown
- **Versions resolved from what each build contains.** A campaign's `app_version` is never written by
  hand: the server resolves the features the campaign requires into, per platform, a lowest version
  `min` and the versions to leave out `exclude` (`{ "ios": { "min": "3.3.0", "exclude": ["3.4.0"] } }`).
  The device only checks its version against that range, and a platform with no range is not shown.
  A campaign whose `app_version` is missing or not in this form is rejected as `invalid`
- **Typed events.** Event values keep their types, so `count gte 3` matches `3`, and a number sent as
  the string `"3"` is reported as `type_mismatch` instead of silently never matching
- **A holdout for every campaign, measured on both sides.** The side comes from the person id
  (`hash32("<project>:<person>:<id>:holdout")`) and never changes once decided. Both sides record
  `campaign_eligible(side)`, so the two groups are comparable, with the
  chance of that side (`propensity`) and the set's version (`policy_version`). When the set's policy
  has `global_holdout: true`, a person with `hash32("<project>:<person>:global_holdout") / 2³² < 0.05`
  is shown no campaign (outcome `global_holdout`) and records no `campaign_eligible`. Your own devices
  are never in it
- **Two variants of a campaign.** A campaign may list two `variants` (`id`, `values`, optional
  `text_key`); each variant's values are laid over the campaign's and checked like `show`. On the shown
  side, the variant comes from `hash32("<project>:<person>:<id>:variant")` and the weights in the set's
  `allocations` (equal weights when there is none; a weight of 0 is a stopped variant). Your own devices
  get the first variant that is not stopped. `campaign_eligible`, `campaign_shown`, `campaign_tapped`,
  `campaign_dismissed` and `campaign_action_completed` carry `variant`, and `propensity` and
  `policy_version` are then the variant's and the allocation's
- **Fails closed.** A launch waits for its first fetch before deciding; offline, the set on hand is
  used within `cache_hours` (72 by default), then nothing is shown. An unreadable set keeps the
  previous one. An unknown placement, action, fact, operator, target or a wrong type skips that
  campaign and is reported once as `campaign_rejected`
- **Measurement goes through your analytics.** The SDK hands `campaign_*`, `app_updated` and
  `link_opened` to a closure and never sends anything itself
- **Works on its own.** `BundledCampaignSetFetcher` reads a set JSON shipped in the app bundle. Any
  `CampaignSetFetching` can fetch it from elsewhere instead
- **No dependencies.** Foundation and Observation; SwiftUI only in `CampaignSwiftUI`

### Types

| Type | Placement (kind) | Action | Notes |
|---|---|---|---|
| `trial_offer` | `CampaignTemplate.TrialOffer` (modal) | `.startTrial(_:)` | The app owns the card and the trial |
| `review_ask` | `CampaignTemplate.ReviewAsk` (system) | `.requestReview(_:)` | Always `completed`; `max_per_app_version: 1` |
| `whats_new` | `CampaignTemplate.WhatsNew` (modal) | a link or an app action | Triggered by `app_updated`, which the SDK records on the first launch of a newer version |
| `cross_promo` | `CampaignTemplate.CrossPromo` (modal) | `.openStorePage(providerToken:open:)` | Opens the App Store page of the set's `targets[target]` and records `link_opened(kind=store_page)` |

A `system` placement (`review_ask`) has no view: when it is shown, its action runs at once.

## Quick Start

Build the engine with the placements, facts and actions your app registers:

```swift
import CampaignCore

let campaigns = CampaignEngine(
    fetcher: BundledCampaignSetFetcher(resource: "campaigns"),   // the set shipped in the app
    context: CampaignContext(appVersion: version, build: build, channel: channel, lang: lang, region: region),
    person: { people.personID },          // a stable id for the person (the install id until you have one)
    isInternalDevice: { debug.isInternalDevice },
    placements: [CampaignTemplate.TrialOffer.self, CampaignTemplate.ReviewAsk.self],
    facts: [
        .device("is_premium", .bool) { .bool(premium.isPremium) },
        .server("trial_eligible", .bool) { try await .bool(trial.isEligible()) },
    ],
    actions: [
        .startTrial { request in await trialFlow.start(from: request.trigger) },
        .requestReview { await review.requestSystemPrompt() },
    ],
    record: { event in analytics.track(event.name, event.parameters) },
    isBusy: { router.hasFullScreen }
)
```

Refresh it, feed it events, and present the placement with your own view:

```swift
import CampaignSwiftUI

RootView()
    .campaignPlacement(CampaignTemplate.TrialOffer.self, in: campaigns) { offer in
        TrialOfferCard(values: offer.values, onPrimary: offer.tap, onClose: { offer.dismiss(.secondary) })
    }
    .task { await campaigns.refresh() }   // and again on return to the foreground

campaigns.observe("paywall_closed", ["result": "continue_free", "source": "habit_limit"])
campaigns.observe("exchange_completed", ["count": 3])   // an Int, not "3"
```

Fire each event once in your analytics, and let the engine hear it as one more destination with the
types intact (this package does not depend on any analytics package):

```swift
struct CampaignAnalyticsTap: AnalyticsClient {
    let campaigns: any CampaignEventObserving
    func track(_ name: String, _ parameters: [String: Any]) {
        campaigns.observe(name, parameters.compactMapValues(CampaignValue.init(any:)))
    }
}
```

In your app's tests, check the registration against `campaigns/manifest.json`:

```swift
try CampaignManifest.verify(campaigns.registry, against: manifestURL)
```

### Connecting to a server

The package works on its own. To connect it to a server, enable the matching trait of the connector package [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) (SwiftPM traits) instead of wiring a server here.

## Documentation

The API reference is the symbol documentation in `Sources/CampaignCore`, `Sources/CampaignSwiftUI`
and `Sources/CampaignTesting`. Open it in Xcode with Product > Build Documentation. Changes are
listed in [CHANGELOG.md](./CHANGELOG.md).

## Installation

```swift
.package(url: "https://github.com/appgrowstack/swift-app-campaign.git", .upToNextMinor(from: "0.6.0"))
```

```swift
.product(name: "CampaignSwiftUI", package: "swift-app-campaign")
```

| Product | Contents | Depends on |
|---|---|---|
| `CampaignCore` | Loader, decision, holdout, engine, templates, registration, manifest check, ports | Foundation, Observation |
| `CampaignSwiftUI` | `.campaignPlacement(_:in:style:isBusy:content:)` | SwiftUI |
| `CampaignTesting` | Fake fetcher, clock, storage, image prefetcher; event recorder | nothing |

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## License

MIT. See [LICENSE](./LICENSE).
