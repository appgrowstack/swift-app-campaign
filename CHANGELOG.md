# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-15

### Added

- `CampaignCore`: the set loader (`CampaignSetLoader`), the pure decision (`CampaignRules.decide`),
  limits, the holdout hash (`CampaignHash`), `CampaignEngine` (fetch with ETag, storage,
  `cache_hours`, waiting while the app is busy, taps and dismissals), placement, fact and action
  registration, `CampaignManifest.verify`, and the `CampaignEventObserving` port.
- `CampaignSwiftUI`: `.campaignPlacement(_:in:style:isBusy:content:)`.
- `CampaignTesting`: `FakeCampaignSetFetcher`, `FakeCampaignClock`, `InMemoryCampaignStorage`,
  `CampaignEventRecorder`, `FakeImagePrefetcher`.
