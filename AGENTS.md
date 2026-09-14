# AI Usage

macOSメニューバーアプリとWidgetKit拡張。`App/` は画面、`Widget/` は拡張、`Shared/` は収集・保存・共通表示、`Tests/` は検証。

- 開発・PRは [CONTRIBUTING.ja.md](CONTRIBUTING.ja.md)、公開時は [docs/RELEASE.md](docs/RELEASE.md)の該当工程を読む。Developer ID署名・公証・DMG・Sparkle配信をTestFlight手順へ置き換えない。
- 公開ソース・Issue・配布物に認証値、個人パス、生ログ・スナップショットを含めない。例は汎用プレースホルダーを使う。詳細は [SECURITY.md](SECURITY.md)。
- 使用率は「消費済み%」。本人の端末データと認証情報は分け、Widgetへは最小の表示用スナップショットだけを渡す。
- UI変更時は日本語・英語の文字列を同期する。ビルド設定の正本は `project.yml`、XcodeGenで生成する。
- 正式名称は `AI Usage`。展開後の `.app` 名に版番号を付けない。既存の共同作業者の著作者・Git履歴を保持する。
- Keychainや認証の修復前に、接続元と現在の設定を確認する。資格情報の削除・再認証を診断の初手にしない。
