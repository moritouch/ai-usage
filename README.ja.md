[English](README.md) | **日本語**

<p align="center">
  <img src="docs/app-icon.png" width="104" height="104" alt="AI Usageのアプリアイコン">
</p>

<h1 align="center">AI Usage</h1>

<p align="center"><strong>AIの使用率を、ひと目で。</strong></p>

<p align="center">
  Claude Code、Codex、Grokの使用率とリセット時刻を、macOSのメニューバーとウィジェットで確認できる無料のオープンソースアプリです。
</p>

<p align="center">
  <a href="https://moritouch.com/ai-usage"><strong>macOS版をダウンロード</strong></a>
  · <a href="https://github.com/moritouch/ai-usage/releases/latest">最新リリース</a>
  · <a href="SECURITY.md">セキュリティ</a>
</p>

<p align="center">macOS 14 Sonoma以降 · MIT License</p>

<p align="center">
  <a href="https://moritouch.com/ai-usage">
    <img src="https://moritouch.com/ai-usage/og-ja-v2.png" width="900" alt="AI Usageのメニューバーと使用率表示">
  </a>
</p>

## 主な機能

- **メニューバー** — 常駐アイコンとポップオーバーで、逼迫している使用枠をすぐ確認
- **ウィジェット** — デスクトップに使用率とリセット時刻を表示
- **複数の使用枠** — Claude Codeの5時間枠・週枠などをエージェントごとに整理
- **カスタマイズ** — 表示するエージェント、カード順、Dock表示を設定
- **日本語／英語** — アプリ本体とウィジェットで言語設定を共有
- **アプリ内アップデート** — 自動確認と手動の「アップデートを確認…」に対応
- **Staleの案内** — 現在値と確認できない場合に、理由と対処方法を表示

表示は一貫して使用済み割合（`used`）です。バーの伸びと色は、緑から黄・橙・赤へ同じ方向に変化します。

## 対応ツールと取得元

| ツール | 取得元 | 主な表示内容 |
|---|---|---|
| **Claude Code** | Anthropic OAuth usage API | 利用可能な5時間枠・週枠・モデル別枠、リセット時刻、プラン |
| **Codex** | `~/.codex/sessions/**/rollout-*.jsonl` | 利用可能なprimary／secondary枠、リセット時刻、プラン |
| **Grok** | `~/.grok/logs/unified.jsonl` | 現在の請求期間の使用率、期間終了時刻、契約種別 |

CodexとGrokはMac内のローカルログを読む受動的な方式です。各ツールを利用してログが更新されるまで、表示値も更新されません。

Claude Codeは、Claude CodeがmacOS Keychainへ保存した既存の認証情報を使って使用率を取得します。access tokenの期限が近い場合はClaude Codeと同じOAuth token endpointで安全に更新し、refresh tokenが回転した場合だけ同じKeychain項目へ書き戻します。AI Usage用のAPIキーを別途作成する必要はありません。

> [!IMPORTANT]
> Claude CodeのOAuth usage APIは、公開された安定契約を確認できない実験的な依存先です。Claude Code側の変更により、予告なく取得できなくなる可能性があります。

Gemini CLIとCursorは、現在のところ必要な使用枠情報をローカルで安全かつ安定して取得できないため未対応です。取得方法を確認できたツールから順次追加する予定です。

## インストール

1. [製品ページ](https://moritouch.com/ai-usage)から、Developer ID署名・Apple公証済みの最新DMGをダウンロードします。
2. DMGを開き、`AI Usage.app`を`Applications`ショートカットへドラッグします。
3. Claude Codeへログインします。CodexとGrokは少なくとも一度通常の応答を完了し、ローカルログを更新します。
4. AI Usageを起動します。Claude CodeのKeychain確認が表示された場合は、配布元と署名者を確認してから判断してください。継続的な更新を許可する場合は「常に許可」を選びます。
5. 設定で言語、エージェントの表示、カード順、アップデート確認を選びます。
6. 必要なら、デスクトップの「ウィジェットを編集」からAI Usageを追加します。

AI Usageはメニューバーで起動している間に値を収集します。ウィジェットだけでは新しい値を収集できません。

## `Stale`について

`Stale`は、表示中の値が現在のものだとAI Usageで確認できない状態です。取得失敗、観測時刻の欠落・不正、最後の有効な観測から6時間以上経過した場合などに表示されます。

- Claude Code：ログイン状態とKeychainの許可を確認し、ヘルプ画面から再確認
- Codex／Grok：各ツールで通常の応答を完了してローカルログを更新
- 共通：`Stale`バッジまたはヘッダーのヘルプから、エージェント別の対処方法を確認

## プライバシーと通信

- メニューバー本体は、Codex／GrokのローカルログとClaude CodeのKeychain認証情報を読むため非サンドボックスです。
- WidgetKit拡張はサンドボックス化され、App Group経由で必要最小限の表示用スナップショットだけを受け取ります。
- **使用率の取得で外部通信を行うのはClaude Codeだけ**です。認証情報はAnthropicのusage APIとOAuth token endpointにだけ送信します。
- Codex／Grokの収集ではAPI呼び出しもトークン消費も発生しません。
- 会話本文、元のJSONLログ、認証情報のコピーをAI Usage運営のサーバーへ送信しません。
- 更新確認を有効にすると、Sparkleが`moritouch.com`の署名済みappcastと公証済みDMGへ接続します。
- OAuth tokenをスナップショット、設定、通常ログへ保存しません。

本体は60秒ごとに収集を試み、Claude CodeのAPI通信には180秒の最小間隔があります。ウィジェットは約10分後の更新をWidgetKitへ要求しますが、実際の更新時刻はmacOSが決定します。

AI UsageはOpenAI、Anthropic、xAI、Appleとは提携していない非公式アプリです。表示値は参考情報で、Appleの公証は機能やプライバシー設計に対する推奨を意味しません。

## アップデート

Sparkle 2.9.6を使用しています。既定では24時間ごとに更新を確認し、設定から自動確認の有効／無効を選ぶか、「アップデートを確認…」でいつでも手動確認できます。Sparkleは署名済みappcastを確認し、Developer ID署名・Apple公証済みのDMGだけを案内します。インストール前にはユーザーが確認します。

過去のバージョンと更新内容は[GitHub Releases](https://github.com/moritouch/ai-usage/releases)にあります。リリース作成・署名・公証・配布の手順は[リリースガイド](docs/RELEASE.md)を参照してください。

## 開発とテスト

Xcodeと[XcodeGen](https://github.com/yonaskolb/XcodeGen)が必要です。リポジトリの設定にはメンテナーのDeveloper Team、bundle identifier、App Groupが含まれています。外部コントリビューターは、それらの署名権限がなくてもCIと同じ署名なしテストを実行できます。

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage \
  -configuration Debug \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO test
```

ローカルでアプリを起動する場合は、`project.yml`、本体とWidgetのentitlements、`Shared/SnapshotStore.swift`にあるDeveloper Team、bundle identifier、App Groupを自分の設定へ一貫して変更し、Xcodeプロジェクトを再生成してください。

開発ビルドは配布用ではありません。Apple Development署名やデバッグ用の`get-task-allow` entitlementを持つ場合があり、再署名・再インストール後にはKeychainの確認が再表示されることがあります。第三者へ配布する場合は、署名・公証済みの正式DMGを使用してください。

## 構成

```text
App/       メニューバー常駐アプリ
Widget/    サンドボックス化されたWidgetKit拡張
Shared/    モデル、収集処理、表示用スナップショット
Tests/     単体テスト
scripts/   開発・statusLine・リリース用スクリプト
```

## 制約

- CodexとGrokはローカルログが更新されるまで値が変わりません。
- Claude Codeの認証情報を安全に更新できない場合は、最後の有効値を`Stale`として表示し、再ログインを案内します。
- 各サービスの非公開または変更可能なログ・API形式に依存するため、提供元の変更で取得できなくなる場合があります。
- ウィジェットの更新時刻はWidgetKitが決定するため保証されません。新しい値を収集するには本体を起動しておく必要があります。
- 表示値は参考情報です。重要な残量は各サービスの公式画面でも確認してください。

## Issue・Pull Request

バグ報告とPull Requestを歓迎します。公開IssueへOAuth token、Keychain内容、完全なJSONLログ、スナップショット、個人パスを投稿しないでください。

開発環境、Pull Request前の確認、プライバシー上の境界は[コントリビューションガイド](CONTRIBUTING.ja.md)を参照してください。

脆弱性はIssueではなく、[Security Policy](SECURITY.md)に記載したGitHub Private Vulnerability Reportingから非公開で報告してください。

## ライセンス

[MIT License](LICENSE)で提供します。第三者の名称・商標と依存関係には、それぞれの権利・ライセンスが適用されます。
