English | [日本語](./README.ja.md)

# swift-app-campaign

Show the right thing to the right person inside your app, without shipping a new build: a campaign
names one of your app's own screens (a placement), the values to fill it with, the event that
triggers it, who it is for, how often, and who is held out for comparison. The device decides.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> Developed in a private monorepo and copied here one way. Issues are welcome; pull requests are
> not accepted.

## Features

- **Your screens only.** A campaign can show only placements your app registered and that passed
  review in your binary. No HTML, no downloaded UI, no visual design in the SDK
- **A pure decision with reasons.** `CampaignRules.decide` reads no clock, storage or network and
  returns the campaign to show, or each campaign's reason not to: stale set → unusable → inactive →
  no trigger → limits → device conditions → server conditions → holdout → priority → text and images
- **Server facts asked last.** A fact from your own server is requested only after every device
  condition has passed
- **A holdout for every campaign.** The same person is always on the same side
  (`hash32("<project>:<person>:<id>:holdout")`), and held-out turns count like shown ones, so the two
  groups are comparable
- **Fails closed.** Offline, the set on hand is used for 72 hours, then nothing is shown. A broken
  set keeps the previous one. An unknown placement, action, fact, operator or a wrong type skips that
  campaign and is reported once as `campaign_rejected`
- **Measurement goes through your analytics.** The SDK hands `campaign_*` events to a closure and
  never sends anything itself
- **No dependencies.** Foundation and Observation; SwiftUI only in `CampaignSwiftUI`

## Quick Start

Register a placement, then build the engine:

```swift
import CampaignCore

struct TrialOfferPlacement: CampaignPlacement {
    static let name = "trial_offer"
    static let fields: [String: CampaignField] = [
        "headline": .text(maxChars: 24), "primary_label": .text(maxChars: 24),
        "secondary_label": .text(maxChars: 12),
    ]
    struct Values: Decodable, Sendable { let headline, primaryLabel, secondaryLabel: String }
}

let campaigns = CampaignEngine(
    projectKey: "pk_…",
    context: CampaignContext(appVersion: version, build: build, channel: channel, lang: lang, region: region),
    person: { auth.uid ?? installID },
    placements: [TrialOfferPlacement.self],
    facts: [
        .device("is_premium", .bool) { .bool(premium.isPremium) },
        .server("trial_eligible", .bool) { try await .bool(trial.isEligible()) },
    ],
    actions: [CampaignAction("start_trial") { request in await trialFlow.start(from: request.trigger) }],
    record: { event in analytics.track(event.name, event.stringParameters) },
    isBusy: { router.hasFullScreen }
)
```

Feed it events, refresh it, and present the placement with your own view:

```swift
import CampaignSwiftUI

RootView()
    .campaignPlacement(TrialOfferPlacement.self, in: campaigns) { offer in
        TrialOfferSheet(values: offer.values, onPrimary: offer.tap, onClose: { offer.dismiss(.secondary) })
    }
    .task { await campaigns.refresh() }   // and again on return to the foreground

campaigns.observe("paywall_closed", ["result": "continue_free", "source": "habit_limit"])
```

With [swift-analytics](https://github.com/no-problem-dev/swift-analytics), add the engine as one
more destination in your app (this package does not depend on it):

```swift
struct CampaignAnalyticsTap: AnalyticsClient {
    let campaigns: any CampaignEventObserving
    func track(_ event: any AnalyticsEvent) {
        campaigns.observe(event.name, event.parameters.mapValues { value in
            switch value {
            case .text(let text): .string(text)
            case .count(let count): .int(count)
            case .number(let number): .double(number)
            case .flag(let flag): .bool(flag)
            }
        })
    }
    func setUserProperty(_ property: any AnalyticsUserProperty) {}
}
```

In your app's tests, check the registration against `campaigns/manifest.json`:

```swift
try CampaignManifest.verify(campaigns.registry, against: manifestURL)
```

## Installation

```swift
.package(url: "https://github.com/no-problem-dev/swift-app-campaign.git", .upToNextMinor(from: "0.1.0"))
```

| Product | Contents | Depends on |
|---|---|---|
| `CampaignCore` | Loader, decision, holdout, engine, registration, manifest check, ports | Foundation, Observation |
| `CampaignSwiftUI` | `.campaignPlacement(_:in:style:isBusy:content:)` | SwiftUI |
| `CampaignTesting` | Fake fetcher, clock, storage, image prefetcher; event recorder | nothing |

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## License

MIT — see [LICENSE](LICENSE).
