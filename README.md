# 番組表 (TVGuide)

SwiftUI で作ったテレビ番組表の iOS アプリです。

## 主な機能

- **番組表**：縦が時刻（5時〜29時）、横がチャンネルのおなじみのグリッド表示
  - ジャンル別の色分け、現在時刻の赤いライン、チャンネル名の固定ヘッダー
  - 起動時に現在時刻付近へ自動スクロール
  - 7日先まで日付を切り替え可能
- **放送中**：いま放送中の番組をチャンネルごとに進捗バー付きで一覧表示
- **検索**：番組名・サブタイトル・内容・出演者でキーワード検索
- **番組詳細**：番組内容・出演者・ジャンル、共有ボタン
- **リマインダー**：放送 N 分前にローカル通知（分数は設定で変更可）

## データソース

| 状態 | 表示されるデータ |
| --- | --- |
| API キー未設定 | サンプルデータ（地上波7局分のダミー番組を日付ごとに生成） |
| API キー設定済み | [NHK 番組表 API](https://api-portal.nhk.or.jp/) の実データ（NHK 各チャンネル） |

民放の番組表は公式の無料 API がないため、実データ化する場合は `ProgramProvider` プロトコルを実装した独自の取得クラスを追加してください（`TVGuide/Services/`）。

## ビルド方法

必要なもの：Xcode 15 以降（iOS 17 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
brew install xcodegen
xcodegen generate
open TVGuide.xcodeproj
```

Xcode でシミュレーターを選んで ▶ を押せば起動します。テストは ⌘U。

XcodeGen を使わない場合は、Xcode で新規 iOS App（SwiftUI）プロジェクトを作り、`TVGuide/` 以下の Swift ファイルを追加してください（テンプレートの `ContentView.swift` と `App` ファイルは削除）。

## 構成

```
TVGuide/
├── App/            アプリのエントリポイント
├── Models/         Channel, Program, Genre, BroadcastDay（5時始まりの放送日）
├── Services/       ProgramProvider（NHK API / サンプル）, ReminderService（通知）
├── ViewModels/     GuideStore（画面全体の状態）
└── Views/          番組表グリッド, 放送中, 検索, 詳細, 設定
TVGuideTests/       ユニットテスト
```
