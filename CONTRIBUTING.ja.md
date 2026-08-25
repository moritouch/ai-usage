[English](CONTRIBUTING.md) | **日本語**

# AI Usageへのコントリビューション

AI Usageの改善にご協力いただきありがとうございます。再現可能なバグ報告、ドキュメント修正、テスト、目的を絞ったPull Requestを歓迎します。

## Issueを作成する前に

- アプリの不具合には既存のバグ報告テンプレートを使用してください。
- AI Usageのバージョン／build番号とmacOSのバージョンを記載してください。
- 問題を再現できる最小限の手順を記載してください。
- OAuth token、Keychain内容、完全なJSONLログ、スナップショット、生のデバッグログ、個人パスを添付しないでください。
- 脆弱性は[SECURITY.md](SECURITY.md)に従い、[GitHub Private Vulnerability Reporting](https://github.com/moritouch/ai-usage/security/advisories/new)から非公開で報告してください。

## 開発環境

Xcodeと[XcodeGen](https://github.com/yonaskolb/XcodeGen)が必要です。

```bash
brew install xcodegen
xcodegen generate
```

リポジトリの設定にはメンテナーのDeveloper Team、bundle identifier、App Groupが含まれています。それらの署名権限がなくても、次のコマンドでテストできます。

```bash
xcodebuild \
  -project AIUsage.xcodeproj \
  -scheme AIUsage \
  -configuration Debug \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  test
```

ローカルでアプリを起動する場合は、`project.yml`、`App/AIUsage.entitlements`、`Widget/AIUsageWidget.entitlements`、`Shared/SnapshotStore.swift`にあるDeveloper Team、bundle identifier、App Groupを自分の設定へ一貫して変更し、Xcodeプロジェクトを再生成してください。

## Pull Request

1つのPull Requestで扱う目的を絞り、ユーザーから見える変更を説明してください。提出前に次を確認します。

1. `xcodegen generate`を実行し、生成された`AIUsage.xcodeproj`の差分が意図したものか確認する。
2. 上記の署名なしテストを実行する。
3. `bash scripts/check-localizations.sh`を実行する。
4. 日本語と英語の表示文言を揃える。
5. 収集、解析、認証情報、表示形式を変更した場合はテストを追加・更新する。
6. 共有モデルや表示を変更した場合は、メニューバー本体とウィジェットの両方を確認する。
7. 個人情報、認証情報、署名素材、公証資格情報、プロバイダーの生ログを含めない。

リリース署名、Apple公証、Immutable GitHub Release、production appcastの配布はメンテナーが行います。Pull Requestへリリース資格情報や生成済み配布物を含めないでください。

## デザインと動作

- 使用率は一貫して使用済み割合（`used`）として表示する。
- リセット時刻を残し、短い使用枠を適切に優先する。
- 各サービスの形式とClaude OAuth usage APIを変更可能な入力として扱い、検証して安全に失敗させる。
- プライバシーへの影響を説明せず、ローカルファイル、Keychain、通信、スナップショットの取得範囲を広げない。
- ウィジェットのサンドボックスを維持し、共有するデータを必要最小限の表示用スナップショットに限定する。

## ライセンス

コントリビューションは、このリポジトリの[MIT License](LICENSE)で提供されることに同意したものとします。
