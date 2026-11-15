[English](./README.md) | 日本語

# swift-app-campaign

アプリを出し直さずに、条件に当たった人へ、アプリの中で何かを勧める。キャンペーンは、アプリ自身の画面（プレースメント）の名前・そこに渡す値・きっかけの出来事・相手の条件・回数・比べるために出さない人（holdout）を書いた物で、判定は端末がする。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> 開発は非公開のモノリポでしていて、ここへは片方向に写すだけです。Issueは受けます。PRは受けません。

## 特徴

- **出すのはアプリの画面だけ。** アプリが登録し、審査を通ったバイナリにあるプレースメントだけを出します。HTML・あとから取る画面・SDKの見た目はありません
- **理由付きの純粋な判定。** `CampaignRules.decide`は時計・保存先・通信を読まず、出す件か、件ごとの出さない理由を返します。順番は、組が古い→使えない件→対象外→きっかけ→回数→端末の条件→サーバーの条件→holdout→優先→文と画像
- **サーバーへの問い合わせは最後。** アプリのサーバーの値は、端末の条件が全部通った件のときだけ聞きます
- **件ごとのholdout。** 同じ人はいつも同じ側（`hash32("<project>:<person>:<id>:holdout")`）。出さない側の回も出した回と同じに数えるので、2つの集まりを比べられます
- **出さない側に倒れる。** 通信できないときは手元の組を72時間まで使い、その後は何も出しません。壊れた組が届いたら前の組を使います。知らないプレースメント・動き・値・演算子や型のずれは、その件だけを飛ばし、`campaign_rejected`を1回だけ記録します
- **計測はアプリの計測へ。** `campaign_*`の出来事をクロージャに渡すだけで、SDKは何も送りません
- **外部の依存は無し。** FoundationとObservationだけ。SwiftUIは`CampaignSwiftUI`の中だけです

## 使い方

コードの例は[README.md](./README.md)のQuick Startと同じです。

1. プレースメントを`CampaignPlacement`で登録する（名前・値の型・`Values`）
2. `CampaignEngine`に公開キー・端末の値・人のid・相手の値（端末の値を先に、サーバーの値は後に）・動き・計測の受け口を渡す
3. 起動と前面に戻ったときに`refresh()`を呼ぶ
4. 計測の出来事を`observe(_:_:)`にも流す（swift-analyticsなら、送り先の1つとして包む）
5. `.campaignPlacement(_:in:)`か`engine.presenting`で、自分の見た目で出す。主のボタンは`offer.tap`、閉じる操作は`offer.dismiss(_:)`
6. アプリのテストで`CampaignManifest.verify(_:against:)`を呼び、登録と`campaigns/manifest.json`が同じかを確かめる

## 導入

```swift
.package(url: "https://github.com/no-problem-dev/swift-app-campaign.git", .upToNextMinor(from: "0.1.0"))
```

## 動作環境

- iOS 17.0以上 / macOS 14.0以上
- Swift 6.2以上

## ライセンス

MIT。[LICENSE](LICENSE)を参照。
