# swift-app-campaign

アプリを出し直さずに、合う人に合う物をアプリの中で出す。出すかどうかは端末が決める。

[English](./README.md)

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

キャンペーンには、アプリ自身の画面（プレースメント）の名前・そこに渡す値・きっかけの出来事・相手の条件・回数・比べるために出さない人（holdout）を書きます。

## 機能

- **出すのはアプリの画面だけ。** アプリが登録し、審査を通ったバイナリにあるプレースメントだけを出します。HTML・後から取る画面・SDKの見た目はありません
- **型ごとの既定。** `trial_offer`・`review_ask`（OSの評価のダイアログだけ。前に何も挟まない）・`whats_new`・`cross_promo` は、既定のプレースメントと動きを持っています（`CampaignTemplate`）
- **理由付きの純粋な判定。** `CampaignRules.decide` は時計・保存先・通信を読まず、出すキャンペーンか、キャンペーンごとの出さない理由を返します。順番は、古い組・使えない・期間外・きっかけ無し・回数・端末の条件・サーバーの条件・holdout・優先・文と画像です
- **待った後にもう一度見る。** ほかの全画面が出ている間は待ち、その後に組と回数を読み直します。待っている間に止めた・一時停止した・期間が終わったキャンペーンは出しません
- **出来事は型のまま。** 出来事の値は型を落とさずに受けるので、`count gte 3` は `3` に当たります。数を文字列の `"3"` で渡すと、当たらないまま気づけない状態にせず `type_mismatch` を記録します
- **どのキャンペーンにもholdoutを置き、両方の側で数える。** 側は人のid（`hash32("<project>:<person>:<id>:holdout")`）で決まり、一度決まったら変わりません。どちらの側も `campaign_eligible(side)` を記録するので、2つの集まりを比べられます
- **出さない側に倒れる。** 起動の直後は最初の取得を待ってから判定します。通信できないときは手元の組を `cache_hours`（既定は72時間）まで使い、その後は何も出しません。読めない組が届いたら前の組を使います。知らないプレースメント・動き・値・演算子・紹介先や型のずれは、そのキャンペーンだけを飛ばし、`campaign_rejected` を1回だけ記録します
- **計測はアプリの計測へ。** `campaign_*`・`app_updated`・`link_opened` をクロージャに渡すだけで、SDKは何も送りません
- **単体で動く。** `BundledCampaignSetFetcher` はアプリのバンドルに同梱した組のJSONを読みます。ほかから取るときは、`CampaignSetFetching` を満たす別の物に差し替えます
- **外部の依存なし。** FoundationとObservationだけ。SwiftUIは `CampaignSwiftUI` の中だけです

### 型

| 型 | プレースメント（種類） | 動き | 補足 |
|---|---|---|---|
| `trial_offer` | `CampaignTemplate.TrialOffer`（modal） | `.startTrial(_:)` | カードとお試しはアプリが持つ |
| `review_ask` | `CampaignTemplate.ReviewAsk`（system） | `.requestReview(_:)` | 結果はいつも `completed`。`max_per_app_version: 1` |
| `whats_new` | `CampaignTemplate.WhatsNew`（modal） | リンクかアプリの動き | きっかけは `app_updated`。新しいバージョンの最初の起動でSDKが記録する |
| `cross_promo` | `CampaignTemplate.CrossPromo`（modal） | `.openStorePage(providerToken:open:)` | 組の `targets[target]` のApp Storeのページを開き、`link_opened(kind=store_page)` を記録する |

`system` のプレースメント（`review_ask`）には画面がありません。出すときに動きをすぐ呼びます。

## はじめに

アプリが登録するプレースメント・値・動きを渡してエンジンを作ります。

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

組を読み直し、出来事を渡し、プレースメントを自分の画面で出します。

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

出来事はアプリの計測で1回だけ送り、エンジンには型を保ったまま、送り先の1つとして聞かせます（このパッケージは計測のパッケージに依存しません）。

```swift
struct CampaignAnalyticsTap: AnalyticsClient {
    let campaigns: any CampaignEventObserving
    func track(_ name: String, _ parameters: [String: Any]) {
        campaigns.observe(name, parameters.compactMapValues(CampaignValue.init(any:)))
    }
}
```

アプリのテストでは、登録した物を `campaigns/manifest.json` と比べて確かめます。

```swift
try CampaignManifest.verify(campaigns.registry, against: manifestURL)
```

### サーバーにつなぐ

このパッケージは単体で使えます。サーバーにつなぐときは、このパッケージで送り先を書く代わりに、コネクターのパッケージ [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) の対応するtrait（SwiftPMのtraits）を有効にします。

## ドキュメント

APIの説明は `Sources/CampaignCore`・`Sources/CampaignSwiftUI`・`Sources/CampaignTesting` のシンボルのドキュメントです。
XcodeのProduct > Build Documentationで開けます。変更は [CHANGELOG.md](./CHANGELOG.md) にあります。

## 入れ方

```swift
.package(url: "https://github.com/appgrowstack/swift-app-campaign.git", .upToNextMinor(from: "0.5.0"))
```

```swift
.product(name: "CampaignSwiftUI", package: "swift-app-campaign")
```

| プロダクト | 中身 | 依存 |
|---|---|---|
| `CampaignCore` | 組の読み込み・判定・holdout・エンジン・型ごとの既定・登録・manifestとの比較・差し替えのためのプロトコル | Foundation・Observation |
| `CampaignSwiftUI` | `.campaignPlacement(_:in:style:isBusy:content:)` | SwiftUI |
| `CampaignTesting` | テスト用の取得・時計・保存先・画像の先読みと、出来事の記録 | なし |

## 動く環境

- iOS 17.0+ / macOS 14.0+
- Swift 6.2+

## ライセンス

MIT。[LICENSE](./LICENSE) を見てください。
