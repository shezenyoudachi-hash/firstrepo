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

## データソース（民放対応）

設定タブの「取得元」で切り替えます。

| 取得元 | 対応チャンネル | 必要なもの |
| --- | --- | --- |
| サンプルデータ | 地上波7局（ダミー） | なし |
| NHK 番組表 API | NHK 各チャンネル | [NHK API ポータル](https://api-portal.nhk.or.jp/)の API キー |
| **Mirakurun** | **民放・NHK の地上波／BS／CS**（実際に受信しているもの） | 自宅の [Mirakurun](https://github.com/Chinachu/Mirakurun) サーバー |
| **XMLTV** | 民放を含む、XMLTV の配信元にあるチャンネル | XMLTV 形式の番組表 URL |

民放には誰でも使える公式の番組表 API がありません。番組表サイトのスクレイピングは多くのサイトで利用規約上禁止されているため、このアプリは**自分で受信した EPG（放送波に含まれる番組情報）**を使う方式で民放に対応しています。

### Mirakurun

チューナー（PX-W3U4 など）をつないだ PC／ラズパイで動いている Mirakurun のアドレスを入力します（例: `192.168.1.10:40772`）。

- 「表示する放送」で 地上波のみ／地上波＋BS／すべて を選べます
- 地上波はリモコン番号順、BS/CS はチャンネル番号順に並びます。局ロゴも表示されます
- 拡張番組情報の「出演者」は出演欄に、それ以外の項目は番組内容に表示されます
- 初回接続時に iOS のローカルネットワーク許可ダイアログが出ます

### XMLTV

EPGStation などの録画サーバーや、EPG 配信サービスが出力する XMLTV の URL を入力します。インターネット上の URL は https のみ対応です（ATS の制限。http はローカルネットワークだけ許可しています）。

## ビルド方法

必要なもの：Xcode 15 以降（iOS 17 SDK）

```sh
git clone -b claude/magical-wright-ziwhzv https://github.com/shezenyoudachi-hash/firstrepo.git
cd firstrepo
open TVGuide.xcodeproj
```

Xcode でシミュレーターを選んで ▶ を押せば起動します。テストは ⌘U。

`TVGuide.xcodeproj` は [XcodeGen](https://github.com/yonaskolb/XcodeGen) で `project.yml` から生成しています。プッシュすると GitHub Actions が自動で再生成・コミットするので、Mac に XcodeGen を入れる必要はありません。ファイルを追加・削除したときは、Xcode で直接いじらずにプッシュして再生成させるか、`xcodegen generate` を実行してください。

## iPhone 実機にインストール

無料の Apple ID でインストールできます（有料の Apple Developer Program は不要）。

1. **Xcode に Apple ID を追加**：Xcode → 設定（⌘,）→ アカウント → 左下の「＋」→ Apple ID
2. **署名の設定ファイルを作成**：ターミナルで
   ```sh
   sh scripts/setup-signing.sh
   ```
   チーム ID と、自分専用のバンドル ID を書いた `Config/Local.xcconfig` が作られます（Git には含まれません）。
3. **iPhone を USB で Mac につなぐ**：iPhone に「このコンピュータを信頼しますか？」と出たら「信頼」
4. **iPhone のデベロッパモードをオン**：iPhone の 設定 → プライバシーとセキュリティ → デベロッパモード → オン（再起動されます）
5. **Xcode を開き直し**、上部のデバイス選択で自分の iPhone を選んで ▶
6. 初回は iPhone で「信頼されていないデベロッパ」と出るので、iPhone の 設定 → 一般 → VPNとデバイス管理 → 自分の Apple ID → 「信頼」。もう一度 ▶

無料の Apple ID の場合、インストールしたアプリは **7日間** で起動できなくなります。そのときは Mac につないで ▶ を押せば再インストールされます。

## 構成

```
TVGuide/
├── App/            アプリのエントリポイント
├── Models/         Channel, Program, Genre, BroadcastDay（5時始まりの放送日）
├── Services/       ProgramProvider（NHK API / Mirakurun / XMLTV / サンプル）, ReminderService（通知）
├── ViewModels/     GuideStore（画面全体の状態）
└── Views/          番組表グリッド, 放送中, 検索, 詳細, 設定
TVGuideTests/       ユニットテスト
```
