# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-11-22

### Added

- The `survey` type: `CampaignTemplate.Survey` (placement kind `sheet`), `CampaignAction.submitAnswer()`,
  and `CampaignEngine.answer(_:choice:)` / `CampaignOffer.answer`, which record `survey_answered`.
  A survey is not shown in a launch where `paywall_closed` was heard. `survey_*` events never trigger.
- `CampaignContext(firstSeenAt:)`: the app's own first-launch date, from before it used this SDK.
  `days_since_first_seen` counts from the earlier of it and the date the engine stored.

### Fixed

- Fetching the set again no longer writes back an old copy of the history (how often each campaign was
  shown) over what was recorded while the set was saved and its images prefetched. The state is read
  after the wait.

## [0.3.0] - 2026-11-21

### Changed

- **Breaking.** `CampaignEngine(fetcher:…)` takes where the set comes from and no longer takes a
  public key or an endpoint.

### Added

- `BundledCampaignSetFetcher`: the set shipped in the app (`app-growth campaigns bundle`), with a
  stable ETag so it is decoded once.
- `CampaignSetFetchFailure(status:)` for fetchers that got neither a set nor "not modified".
- `CampaignSDK.name` and `CampaignSDK.version`, for a connector to report when it fetches sets.

### Removed

- `HTTPCampaignSetFetcher`. Fetching from a server is a fetcher in a separate connector package.

## [0.2.0] - 2026-11-21

Rebuilt on the appgrowstack contract (K1). Not compatible with 0.1.0: there are no aliases for the
old names.

### Changed

- Sets are fetched from `https://api.appgrowstack.com/v1/campaigns/sets/<public key>`
  (`HTTPCampaignSetFetcher.stagingEndpoint` for staging). `CampaignEngine(projectKey:)` and
  `HTTPCampaignSetFetcher(projectKey:)` are now `publicKey:`.
- `campaign_held_out` is gone. Every campaign that passes the conditions up to the holdout records
  `campaign_eligible(side)`, `side` being `treatment` or `holdout`, so both sides are counted as
  "people who passed the conditions".
- The holdout side is decided by the person id (R2: the install id a person was first seen with,
  as `identify` answers it) and remembered on the device: once decided, a side does not change.
  `CampaignHash.isHeldOut` is now `CampaignHash.side(project:person:campaign:holdout:internalDevice:)`
  with `CampaignHash.unit(project:person:campaign:)`.
- Whether this is the owner's device is read on every decision: `CampaignContext.internalDevice`
  moved to `CampaignEngine(isInternalDevice:)`.
- Events that arrive before the launch's first fetch has finished wait for it, so a launch does not
  decide with an old set. When the fetch fails, the stored set is used while it is within
  `cache_hours`.
- `CampaignTriggerEvent(name:properties:)` is now `CampaignObservedEvent(name:props:)`
  (`ObservedEvent`). Values keep their types; `observe(_:_:)` takes `props`.
- `CampaignManifest.app` is now `project`. Placements and actions may name a `template`.
- A set must carry `targets` (may be empty); version 0 is a valid, empty set.
- A campaign must carry a `type` (`trial_offer`, `review_ask`, `whats_new`, `cross_promo`, `custom`),
  read as `Campaign.type`.
- `CampaignDecisionInput` and `CampaignDecision` carry the new fields
  (`internalDevice`, `sessionSeconds`, `sides`, `eligible`).

### Added

- C4: after waiting for the screen, steps 3–5 run again with the set and counts on hand then. A
  campaign that left the set is `withdrawn` (`campaign_skipped(reason=withdrawn)` with the new set
  version); a paused, ended or limited one is not shown. `CampaignRules.recheck(_:_:)`, and the
  outcomes `busy` and `withdrawn`.
- C5: with a `text_key`, a required text that is not in `values` is not rejected when the set is
  read; it comes from the app's table when the campaign is chosen, or the campaign is skipped as
  `missing_locale`. Required values of other types stay required.
- C6: typed values compare as numbers and booleans (`3` equals `3.0`); a string where a number or a
  boolean is expected records `campaign_rejected(type_mismatch)`. `CampaignValue(any:)` reads
  `[String: Any]` from analytics clients by real type.
- `limits.max_per_app_version`, counted in `CampaignRecord.shownByAppVersion` (held-out turns too).
- `campaign_rejected(unknown_target)`: an `open_store_page` whose `target` is not in the set's `targets`.
- Placement kind `system`: no look; showing it runs the `on_tap` action at once and does not record
  `campaign_tapped`.
- `CampaignTemplate.TrialOffer`, `.ReviewAsk`, `.WhatsNew`, `.CrossPromo`, and the actions
  `CampaignAction.startTrial(_:)`, `.requestReview(_:)`, `.openStorePage(providerToken:open:)`
  (records `link_opened(kind=store_page)`). `CampaignManifest.templateDifferences` and `verify`
  compare template placements with these.
- `app_updated(from_version, to_version)`: recorded and decided as an event on the first launch of a
  newer version. `app_updated` passed in by the app is ignored.
- The SDK fact `session_seconds`.
- `CampaignEngine.sides`; `CampaignSet.targets` (`CampaignTarget`); `CampaignActionRequest.target`.

### Removed

- `CampaignEvent.heldOut`, `CampaignHash.isHeldOut`, `CampaignContext.internalDevice`,
  `CampaignTriggerEvent`.

## [0.1.0] - 2026-11-15

### Added

- `CampaignCore`: the set loader (`CampaignSetLoader`), the pure decision (`CampaignRules.decide`),
  limits, the holdout hash (`CampaignHash`), `CampaignEngine` (fetch with ETag, storage,
  `cache_hours`, waiting while the app is busy, taps and dismissals), placement, fact and action
  registration, `CampaignManifest.verify`, and the `CampaignEventObserving` port.
- `CampaignSwiftUI`: `.campaignPlacement(_:in:style:isBusy:content:)`.
- `CampaignTesting`: `FakeCampaignSetFetcher`, `FakeCampaignClock`, `InMemoryCampaignStorage`,
  `CampaignEventRecorder`, `FakeImagePrefetcher`.
