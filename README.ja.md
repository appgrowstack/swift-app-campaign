[English](./README.md) | 日本語

# swift-app-campaign

アプリを出し直さずに、条件に当たった人へ、アプリの中で何かを勧める。キャンペーンは、アプリ自身の画面（プレースメント）の名前・そこに渡す値・きっかけの出来事・相手の条件・回数・比べるために出さない人（holdout）を書いた物で、判定は端末がする。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> 開発は非公開のモノリポでしていて、ここへは片方向にコピーするだけです。Issueは受けます。PRは受けません。

## 特徴

- **出すのはアプリの画面だけ。** アプリが登録し、審査を通ったバイナリにあるプレースメントだけを出します。HTML・あとから取る画面・SDKの見た目はありません
- **型の既定。** `trial_offer`・`review_ask`（OSの評価の窓だけ。前に何も挟まない）・`whats_new`・`cross_promo`は、既定のプレースメントと動きを持っています（`CampaignTemplate`）
- **理由付きの純粋な判定。** `CampaignRules.decide`は時計・保存先・通信を読まず、出す件か、件ごとの出さない理由を返します。順番は、組が古い→使えない件→対象外→きっかけ→回数→端末の条件→サーバーの条件→holdout→優先→文と画像
- **待った後にもう一度見る。** ほかの全画面が出ている間は待ち、閉じた後に組と回数を読み直します。待っている間に止めた・止まった・期間が終わった件は出しません
- **出来事は型のまま。** 出来事の値は型を落とさずに受けるので、`count gte 3`は`3`に当たります。数を文字列`"3"`で渡すと、当たらないまま気づけないのでなく、`type_mismatch`を記録します
- **件ごとのholdoutを、両方の側で数える。** 側は人のid（`hash32("<project>:<person>:<id>:holdout")`）で決まり、一度決まったら変えません。どちらの側も`campaign_eligible(side)`を記録するので、2つの集まりを比べられます
- **出さない側に倒れる。** 起動の直後は最初の取得を待ってから判定します。通信できないときは手元の組を`cache_hours`（既定72時間）まで使い、その後は何も出しません。読めない組が届いたら前の組を使います。知らないプレースメント・動き・値・演算子・紹介先や型のずれは、その件だけを飛ばし、`campaign_rejected`を1回だけ記録します
- **計測はアプリの計測へ。** `campaign_*`・`app_updated`・`link_opened`をクロージャに渡すだけで、SDKは何も送りません
- **単体で動く。** `BundledCampaignSetFetcher`がアプリに同梱した組を読みます。サーバーから取るのは`CampaignSetFetching`を満たす別の物です
- **外部の依存は無し。** FoundationとObservationだけ。SwiftUIは`CampaignSwiftUI`の中だけです

## 使い方

コードの例は[README.md](./README.md)のQuick Startと同じです。

1. プレースメントを登録する。型の物は`CampaignTemplate`の物をそのまま使い、ほかは`CampaignPlacement`で書く（名前・値の型・`Values`）
2. `CampaignEngine`に組の出どころ（アプリに同梱した組は`BundledCampaignSetFetcher(resource: "campaigns")`。`app-growth campaigns bundle`がアプリの`campaigns/`から作る）・端末の値・人のid（`identify`の答えの`person_id`。それまではinstall id。uidは渡さない）・本人の端末か（判定のたびに読む）・相手の値（端末の値を先に、サーバーの値は後に）・動き・計測の受け口を渡す
3. 起動と前面に戻ったときに`refresh()`を呼ぶ。起動の直後に届いた出来事は、この最初の取得を待ってから判定する
4. 計測の出来事を`observe(_:_:)`にも型のまま流す（`[String: Any]`なら`CampaignValue(any:)`で読む）。`app_updated`はSDKが出すので流さない
5. `.campaignPlacement(_:in:)`か`engine.presenting`で、自分の見た目で出す。主のボタンは`offer.tap`、閉じる操作は`offer.dismiss(_:)`。kindが`system`の物（`review_ask`）は見た目を持たず、出した時に動きがすぐ動く
6. アプリのテストで`CampaignManifest.verify(_:against:)`を呼び、登録と`campaigns/manifest.json`が同じか、`template`を書いたプレースメントが型の既定と同じかを確かめる

## 型

| 型 | プレースメント（kind） | 動き | 中身 |
|---|---|---|---|
| `trial_offer` | `CampaignTemplate.TrialOffer`（modal） | `.startTrial(_:)` | カードとお試しはアプリが持つ |
| `review_ask` | `CampaignTemplate.ReviewAsk`（system） | `.requestReview(_:)` | いつも`completed`。`max_per_app_version`は1 |
| `whats_new` | `CampaignTemplate.WhatsNew`（modal） | リンクかアプリの動き | きっかけは`app_updated`（新しいバージョンの最初の起動でSDKが記録する） |
| `cross_promo` | `CampaignTemplate.CrossPromo`（modal） | `.openStorePage(providerToken:open:)` | 組の`targets[target]`のApp Storeの製品ページを開き、`link_opened(kind=store_page)`を記録する |

## 導入

```swift
.package(url: "https://github.com/appgrowstack/swift-app-campaign.git", .upToNextMinor(from: "0.3.0"))
```

0.2.0は0.1.0と互換がありません。変わった所は[CHANGELOG.md](CHANGELOG.md)。

## 動作環境

- iOS 17.0以上 / macOS 14.0以上
- Swift 6.2以上

## ライセンス

MIT。[LICENSE](LICENSE)を参照。
