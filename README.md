# AI Usage

各 AI エージェントの使用率とリセット時刻を、macOS のメニューバーとウィジェットで見るアプリ。
ブラウザや各ツールの画面を開かずに、いま何割使ったかが分かる。

## 何がどこから取れるか

`claude` / `codex` / `grok` / `gemini` / `cursor-agent` のいずれにも残量を出すサブコマンドは無い。
代わりに、各ツールが持っている経路から取る。

| エージェント | 取得元 | 取れる値 |
|---|---|---|
| **Claude Code** | OAuth usage API | 5 時間枠・週枠の使用率、リセット時刻、プラン |
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` | 週枠の使用率、リセット時刻、プラン |
| **Grok** | `~/.grok/logs/unified.jsonl` | 週枠の使用率、期間終了時刻、契約種別 |
| Gemini CLI / Cursor | — | 残量をローカルに出さないため未対応 |

**Claude Code** は `/usage` が叩くのと同じエンドポイント（`api.anthropic.com/api/oauth/usage`）を
使う。トークンは Claude Code が Keychain に保存しているものを読むため、初回や再署名・
再インストール後などに macOS の許可ダイアログが出ることがある。`User-Agent` を
`claude-code/<version>` にしないと厳しい 429 バケットに
落ちるので、実際に動いている Claude Code のバージョンを転写している。

この経路だけが能動的に取りに行けるので、Claude Code が起動していなくても値が更新される。
予備として statusLine 経由の取得も残してある（`scripts/claude-statusline.sh`。ターミナル版
でのみ発火し、通信も Keychain も使わない）。

**Codex** と **Grok** はログを読むだけで、API 呼び出しもトークン消費も発生しない。
ただし受動的な経路なので、そのツールを動かした時にしか新しい値が出ない。
表示中の値を現在値と確認できない場合は `Stale` バッジで知らせる。
取得失敗、観測時刻の欠落・不正、最後の有効な観測から 6 時間以上の経過などが該当する。
バッジまたはヘッダーのヘルプボタンを押すと、エージェント別の対処方法と再確認ボタンを開ける。

## 使い方

- **メニューバー** — 常駐アイコンに、いちばん逼迫している枠の使用率が出る。クリックで一覧。
- **ウィジェット** — デスクトップを右クリック >「ウィジェットを編集」>「AI Usage」。
  小サイズは 5 時間枠のような短い窓を主役にし、中サイズはエージェントごとにまとめ、全体で最大 4 枠を並べる。
  「ウィジェットを編集」で対象を選べるが、1 エージェントが複数の枠を使うことがある。
- **並べ替え** — 一覧でカードをドラッグするか、カード右端の並べ替えメニューを使う。
  先頭が見出しになる。
  設定の「カードの順序」から自動判定（短い窓を優先）に戻せる。
- **言語** — 設定の Language で日本語と English を切り替える。アプリ本体とウィジェットで共有される。
- **アップデート** — 設定から自動確認の有効／無効を選び、「アップデートを確認…」でいつでも手動確認できる。
- **Dock** — 歯車 >「General」>「Show in Dock」を入れると Dock にも出る。
  アイコンを押すと独立ウィンドウが開く。

表示は一貫して「使用量（used）」。バーの伸びと色（緑 → 黄 → 橙 → 赤）が同じ向きを指す。

## 構成

```
App/       メニューバー常駐アプリ（非サンドボックス。~/.codex 等と Keychain を読む）
Widget/    WidgetKit 拡張（サンドボックス必須。App Group 経由で受け取るだけ）
Shared/    モデル・収集ロジック・保存先（両ターゲットで共有）
scripts/   statusLine シム、アイコン生成、リリース
```

本体が 60 秒ごとに収集し、App Group コンテナ
`~/Library/Group Containers/WTKUV8PPM7.jp.co.forestx.aiusage/snapshot.json` に書く。
ウィジェットはそれを読んで描画し、10 分後のタイムライン更新を要求する。
更新時刻は WidgetKit がシステム状況に応じて決めるため、10 分は保証値ではない。
Claude Code の API は 180 秒キャッシュを挟むので、60 秒ごとの収集でも通信は 3 分に 1 回。

ウィジェット拡張は macOS の要件でサンドボックスが必須で、その中からは `~/.codex` を読めない。
そのため収集は本体だけが行い、拡張は受け取り専用にしている。

## プライバシーと通信

- 本体はローカルの利用状況を集めるため非サンドボックスで動く。主に
  `~/.codex/sessions/**/rollout-*.jsonl`、`~/.grok/logs/unified.jsonl`、
  User-Agent のバージョン判定用に `~/.claude/projects/**/*.jsonl`、Claude Code の
  Keychain 項目 `Claude Code-credentials` を読む。statusLine を導入した場合は
  `~/Library/Application Support/AIUsage/claude.json` も読む。
- 利用状況の取得で外部通信を行うのは Claude Code だけで、Keychain から読んだ OAuth トークンを
  Anthropic の `https://api.anthropic.com/api/oauth/usage` へ送る。トークンをアプリの
  snapshot、設定、ログへ保存しない。Codex と Grok の取得はローカルファイルの読み取りだけ。
- アップデート確認を有効にした場合、Sparkleが
  `https://moritouch.com/ai-usage/appcast.xml` を確認する。更新を実行すると、appcastに記載された
  `https://moritouch.com/ai-usage/releases/<version>/` 配下の公証済みDMGをHTTPSで取得する。
- statusLine の生入力ログは既定で無効。`AIUSAGE_DEBUG=1` を明示した場合だけ
  `~/Library/Application Support/AIUsage/statusline-raw.log` に保存するため、デバッグ後は
  環境変数とログを削除する。

## インストール（配布版）

macOS 14 Sonoma 以降が必要。

通常利用には、配布担当者から受け取った**公証済み DMG**を使う。DMG を開き、
`AI Usage.app` を同梱の `Applications` ショートカットへドラッグしてから起動する。
DMG内にはドラッグ先と、初回起動後の設定を日英で表示する。

初回は次を確認する。

1. Claude Codeへログインする。CodexとGrokは少なくとも1回通常の応答を完了し、
   ローカルログを作成・更新する。
2. AI Usageを起動する。使用量は自動で確認される。Claude CodeのKeychain確認が表示された場合は、
   公証済み配布版と署名者を確認し、「常に許可」を選ぶと継続更新できる。
3. 設定の「言語 / Language」で日本語またはEnglishを選び、エージェントの表示／非表示を選ぶ。
   カードは使用量一覧でドラッグするか、各カードの並べ替えメニューで順序を変える。
4. 必要ならmacOSの「ウィジェットを編集」からAI Usageを追加し、表示するエージェントを選ぶ。
   値を更新するにはAI Usage本体を起動しておく。

`0.1.9`（build `11`）はSparkleを初めて組み込むbootstrap版のため、それ以前の版からは
公証済みDMGを入手し、実行中のAI Usageを終了して手動で置き換える必要がある。
`0.1.9`以降では設定から自動確認を有効にするか、「アップデートを確認…」を押して更新できる。
実更新の最初のE2E検証は、`0.1.9`をインストールした状態から`0.1.10`へ更新して行う。
配布物の作成・検証方法は [docs/RELEASE.md](docs/RELEASE.md) を参照。

## 開発用ビルドと再起動

ソースから動かす場合は Xcode と XcodeGen が必要。AI Usage を終了してから次を実行する。

```bash
brew install xcodegen          # 初回のみ
xcodegen generate
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Debug -derivedDataPath build/development \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile build
open "build/development/Build/Products/Debug/AI Usage.app"
```

これはローカル開発専用の成果物。署名環境によっては `Apple Development` 署名になり、
デバッグ用の `get-task-allow` entitlement を持つことがあるため、そのまま第三者へ配布しない。
配布には上記の公証済み DMG を使う。

Keychain の許可を求められた場合は、公証済み配布版と署名者を確認してから判断する。
「常に許可」を選ぶと継続的な更新が可能になるが、再署名・再インストール・Keychain設定変更後は
再度確認されることがある。拒否しても Codex / Grok のローカル収集は利用できる。
ログイン時に起動したい場合はシステム設定 >「一般」>「ログイン項目」に追加する。

ターミナルで Claude Code を使っていて、予備の statusLine 経路も入れたい場合:

Claude Code を終了してから実行する。スクリプトは同時実行と途中の設定変更を検知して停止し、
導入時・解除時とも復元用バックアップを `~/.claude/` に 0600 権限で残す。

```bash
./scripts/install-claude-statusline.sh   # 解除は uninstall-claude-statusline.sh
```

アプリアイコンは `scripts/make-icon.swift` で生成している。配色や塗り位置を変えて作り直せる。

## 解除

```bash
./scripts/uninstall-claude-statusline.sh   # statusLine を入れた場合のみ
rm -rf "/Applications/AI Usage.app"
rm -rf ~/Library/Group\ Containers/WTKUV8PPM7.jp.co.forestx.aiusage
rm -rf ~/Library/Application\ Support/AIUsage
```

## 配布

直接配布用のビルドと更新feedの手順は [docs/RELEASE.md](docs/RELEASE.md) を参照。

正規の紹介ページは [moritouch.com/ai-usage](https://moritouch.com/ai-usage)、Sparkle feedは
`https://moritouch.com/ai-usage/appcast.xml`。どちらもmoritouchのCloudflare配信を正本とし、
このリポジトリからGitHub Pagesは配信しない。署名・公証済みDMG、同名の`.sha256`、署名済み
appcastをprofile WorkerのStatic Assetsへ固定version pathで配置する。紹介ページは最新の
公証済みDMGとSHA-256への直接導線を提供し、非公開repositoryへはリンクしない。

- [.github/workflows/release.yml](.github/workflows/release.yml) — 非公開Draftと内部assetを、checkoutなし・read-only APIで検査
- [SECURITY.md](SECURITY.md) — 送ってはいけない診断情報と一般配布前の窓口要件

非公開GitHub Releaseの確定は自動化せず、別担当者がDraft、固定tag、DMG、SHA-256、公証結果を
確認してから手動で行う。確定済みimmutable Releaseとローカル成果物を照合したあとに、
Workers配信用assetとappcastを生成し、moritouchのprofile repositoryからCloudflareへdeployする。

## ライセンス

本ソフトウェアは[MIT License](LICENSE)で提供する。第三者の名称・商標や、同梱する依存関係には
それぞれの権利・ライセンスが適用される。repositoryの公開範囲とは別に、配布物へLICENSEと
Third-Party Noticesを同梱する。

## 制約

- Codex と Grok はログ由来なので、そのツールを動かすまで値が変わらない。
- Grok の `creditUsagePercent` は 0 のときフィールドごと省略される。欠落は 0 として扱っている。
- プラン名は内部識別子で来ることがあるため `Shared/PlanLabel.swift` で表記を揃えている。
  等級（`prolite`、`max_5x` など）は表に出さず `Pro` / `Max` に寄せる。
- Claude Code のトークンが期限切れの場合は取得できない。Claude Code 側で再ログインすると直る。
- Claude Code の OAuth usage API は公開された安定契約を確認できていない実験的な依存先。
  Claude Code 側の変更により、予告なく取得できなくなる可能性がある。
