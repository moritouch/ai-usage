# Security Policy

## 脆弱性を報告する

脆弱性や、認証情報・個人情報が意図せず公開される問題は、公開Issueへ書かないでください。
リポジトリでGitHub Private Vulnerability Reportingを有効にし、GitHubの
**Security > Report a vulnerability** から非公開で報告してください。

Private Vulnerability Reportingが利用できない場合は、公開Issueには詳細を載せず、
「非公開の連絡方法が必要」とだけ記載してください。監視が確認できていないメールアドレスや
個人の連絡先は、この文書へ仮置きしません。

報告には、可能な範囲で次を含めてください。

- AI Usageのバージョンとbuild番号
- macOSのバージョン
- 影響と再現条件の要約
- 秘密情報を除いた最小限のエラー内容

次の内容は送らないでください。

- OAuth token、Authorization header、Keychainの内容
- Claude Code、Codex、Grokの完全なJSONLログ
- `statusline-raw.log`、snapshot、`settings.json`、statusLineのバックアップ
- ユーザー名やホームディレクトリを含む未加工の画面・ログ
- Developer ID秘密鍵、公証資格情報、CI secret

## サポート対象

セキュリティ修正は原則として最新の公開版で提供します。AI Usage 0.1.9以降は、
設定の「アップデートを確認…」から署名済み更新フィードを確認できます。最初の
Sparkle搭載版である0.1.9への移行だけは、GitHub Releasesの公証済みDMGと
SHA-256を確認して手動で置き換えてください。

Appleの公証はマルウェア・署名上の自動確認であり、Appleによる機能、プライバシー、
セキュリティ設計全体の承認や推奨を意味しません。
