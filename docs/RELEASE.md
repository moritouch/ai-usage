# リリース手順

App Store外でDeveloper IDによる直接配布を行う。通常のリリースはアプリとDMGを公証し、
両方にチケットをステープルしてからGatekeeper判定まで確認する。

正規の紹介ページは `https://moritouch.com/ai-usage`、Sparkle feedは
`https://moritouch.com/ai-usage/appcast.xml` とし、moritouchのCloudflare配信を正本にする。
更新DMGはGitHub Releasesだけへ置き、Cloudflare側へ複製しない。ソースコードの公開ライセンスはMIT。

```bash
./scripts/bootstrap-release-tools.sh
./scripts/bootstrap-sparkle-tools.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --help
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh
```

`DEVELOPER_DIR`にはstable Xcodeの`Contents/Developer`を指定する。通常の公証済みreleaseでは、
実効Xcode.appに`BetaVersion.plist`があるbeta distributionをpreflightで拒否する。
`xcode-select`がbetaを向いていても、この環境変数を付けた`xcrun`/`xcodebuild`の実効pathを検証し、
release記録にも同じDeveloper directory、Xcode.app、release channelを保存する。

正規成果物は `dist/AIUsage-<version>.dmg`、公開用ハッシュは同名の `.sha256`。
DMGには `AI Usage.app` と `/Applications` へのシンボリックリンクが入り、Finderを開くと
アイコン表示、固定位置、ドラッグ矢印、初回設定の日英案内が表示される。
同じversionの成果物が既にある場合は上書きせず停止するので、version/buildを上げるか
既存成果物を安全な場所へ退避する。releaseと固定toolchain準備は共通lockで直列化され、
別processが実行中なら開始しない。DMGはrun固有のworking pathで作成し、レイアウト、署名、公証、
Gatekeeper、同梱アプリをすべて検証したあとだけ`dist/`へ配置する。

## 初回だけ必要な準備

配布に使うApple DeveloperチームのTeam IDは `WTKUV8PPM7`。秘密鍵、App用パスワード、
公証資格情報をリポジトリ、チャット、CIログへ置かない。

### 1. Developer ID Application証明書を作る

通常のローカルDeveloper ID証明書を新規作成できるのは原則としてAccount Holder。
Adminを使う場合は、Apple側でcloud-managed Developer ID certificate accessが明示的に
付与された運用と混同しないこと。

Xcode > Settings > Accounts > 配布用Apple Developerチーム > Manage Certificates >
左下の `+` > **Developer ID Application** から作成する。

別の署名担当者から `.p12` を受け取る必要がある場合は、強い一時パスフレーズと
承認済みの安全な経路を使う。リポジトリ外で受け渡し、Keychainへのimport後は受渡し用
ファイルを残さない。漏えいが疑われる場合は使用を止め、Account HolderとAppleへ連絡する。

Team IDまで含めて確認する:

```bash
security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "(WTKUV8PPM7)"
```

### 2. App用パスワードを発行する

appleid.apple.com > サインインとセキュリティ > App用パスワード > 新規発行。
名前は「AIUsage notarization」など用途が分かるものにする。Apple IDの通常パスワードは
使用しない。

### 3. 公証資格情報をKeychainへ保存する

`--password` をコマンド行へ書くとshell historyやprocess listへ残り得る。
省略して、`notarytool` の安全な対話プロンプトでApp用パスワードを入力する。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun notarytool store-credentials "AIUsage" \
  --apple-id <Apple ID> \
  --team-id WTKUV8PPM7
```

資格情報はKeychainへ保存され、release scriptはprofile名だけを参照する。
別profileを使う場合は `NOTARY_PROFILE` を指定する。

### 4. 固定DMG toolchainを準備する

DMGのFinderレイアウトは`dmgbuild`で生成する。依存versionと配布ファイルのhashは
`packaging/dmg/requirements.txt`へ固定してあり、release中にはinstallしない。初回またはlock更新後に
次を実行し、Git管理外の`build/release-tools/venv`へ準備する。

```bash
./scripts/bootstrap-release-tools.sh
```

bootstrapはwheel由来のinstalled file hashを検証し、requirements hash、Python、各packageの実測versionを
`build/release-tools/toolchain-stamp.txt`へ保存する。preflightとDMG生成直前・直後に同じ内容を再検証する。

### 5. 固定Sparkle toolchainと署名鍵を確認する

公式配布のSparkle `2.9.6` toolsを固定SHA-256で検証し、Git管理外の
`build/sparkle-tools/2.9.6/bin/`へ準備する。

```bash
./scripts/bootstrap-sparkle-tools.sh
build/sparkle-tools/2.9.6/bin/generate_keys \
  --account jp.co.forestx.aiusage -p
```

秘密鍵はlogin Keychainのaccount `jp.co.forestx.aiusage`にだけ保持する。`-p`は既存鍵の公開鍵を
表示するだけであり、その値が`App/Info.plist`の`SUPublicEDKey`と一致することを確認する。
既存鍵が見つからない場合は勝手に再生成せず、署名鍵の管理担当者へ確認する。秘密鍵をrepository、
release asset、Cloudflare環境変数、CI secretへ置かない。

### 6. preflightを通す

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
```

preflightはstable Xcode/XcodeGen、固定versionの`dmgbuild`と各種配布コマンド、
Team IDが一致するDeveloper ID証明書、
公証profile、リポジトリ内の秘密鍵、同version成果物の衝突を検査する。さらにproject root自体が
Git repository rootで、有効な40桁のHEAD commitがあり、未commit・未追跡ファイルを含めworktreeが
cleanであることを必須にする。通常の`--check`と公証済みreleaseはGit情報が取得不能またはdirtyなら
失敗する。公証なしローカル検証だけは警告して継続できるが、その成果物は配布しない。
公証profileの検証はAppleへの読み取りリクエストを伴うため、資格情報の不備とネットワーク障害の
双方を確認する。

`build/release.lock`が残って停止した場合は、releaseまたはbootstrapのprocessが本当に動いていないことを
確認する。異常終了で残った空directoryだと確認できた場合に限り、`rmdir build/release.lock`で解除する。

このscriptはApp ID、App Group、capabilityをApple Developer側へ自動登録しない。
署名担当者は、必要なidentifier/capabilityがApple Developer側の設定と一致すること、および
export後のアプリとWidgetに期待するentitlementsが含まれることをリリースごとに確認する。
新しいMacではXcodeへのサインインやローカル署名資産の準備も別途必要になる場合がある。

## 配布物を作る

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh
```

成功時に次を出力する。

- `dist/AIUsage-<version>.dmg`
- `dist/AIUsage-<version>.dmg.sha256`
- release記録の `provenance.json` とそのSHA-256
- アプリ/DMGそれぞれの公証response、submission ID、公証log
- ソースファイルmanifest、Xcode/XcodeGen/SDK、証明書fingerprint、build/export log
- Git commit由来のDMG設定・背景renderer snapshot、固定toolchain stampと実測version
- アプリ/Widgetのexported entitlements、dSYMと各file manifest、xcarchiveの`Info.plist`

release記録の既定保存先は `build/release-records/<run-id>/`。長期保管が必要な本番運用では、
アクセス制御されたリポジトリ外の絶対パスを指定する。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RELEASE_RECORD_DIR=/absolute/private/release-records \
  ./scripts/release.sh
```

公証が失敗または中断した場合、`provenance.json` の `submissionId` とstatusを確認する。
Apple側でAccepted済みか不明なままscript全体を再実行して重複submitしない。
記録されたIDを使って `notarytool info` / `notarytool log` で照合してから再開方針を決める。

配布前に、最終DMGのSHA-256、`spctl`、`stapler validate`、DMG内アプリのbundle ID、
version/build、Team IDがrelease記録と一致することを別担当者が確認する。

## GitHub Releasesで公開する

Git worktree、GitHub repository、remote、default branchのどれかが未準備ならGitHub公開を開始しない。
この手順と`.github/workflows/release.yml`をdefault branchへ取り込み、remote上のcommitとCIを確認してから進む。
repository URLや個人アカウント名をファイルへ埋め込まず、実際のrepository contextから取得する。

Apple署名・公証の正本は管理下Macで実行する`./scripts/release.sh`である。Developer ID秘密鍵、`.p8`、
App用パスワード、notary profileをGitHub Actionsのrepository/environment secretへ登録しない。
`release.yml`は`workflow_dispatch`だけを受け付け、read-onlyの`GITHUB_TOKEN`で既存Draftを検査する。
PR codeをcheckout・実行せず、Draftの作成、asset upload、Publish、Apple署名・公証は一切行わない。

### 初回のGitHub設定

1. repository rootへMITの`LICENSE`を置き、公開対象に秘密情報や個人固有値がないことを確認する。
2. default branchと`v*` tagをrulesetで保護し、workflow変更、tag作成、Release公開を担当者へ限定する。
3. Repository SettingsのReleasesで**release immutability**を有効にする。これは有効化後に公開する
   Releaseだけへ適用されるため、最初の公開前に設定する。
4. ActionsへApple関連secretを作らない。workflow-level permissionは`contents: read`のままにする。
5. GitHub Releaseの最終Publishは、署名担当者とは別の承認者がGitHub UIから手動で行う。
6. GitHub Pagesを過去に公開していた場合はSettings > Pagesからunpublishし、Cloudflareの紹介ページと
   appcastだけを正規配信面にする。

GitHubのimmutable releaseは公開後のtag移動・削除とasset変更・削除を防ぎ、公開時のtag、commit、
assetsに対するattestationを生成する。これはGitHub上の公開集合の証跡であり、管理下MacでのApple
build provenanceの代替ではない。Draftは公開前なら変更可能なので、asset検査をすべて終えてからPublishする。

### 1. 管理下Macで正規成果物を作る

version変更をdefault branchへcommit/pushし、手元がcleanでそのcommitがdefault branch履歴上にあることを
確認する。ビルド後の`provenance.json`はアクセス制御された非公開保管先だけに残す。

```bash
set -euo pipefail
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git fetch origin "$DEFAULT_BRANCH" --tags
test "$(git branch --show-current)" = "$DEFAULT_BRANCH"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$DEFAULT_BRANCH")"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/release.sh --check
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RELEASE_RECORD_DIR=/absolute/private/release-records \
  ./scripts/release.sh
```

scriptが表示した非公開`provenance.json`について、`source.gitState`が`clean`、`source.gitCommit`が
`git rev-parse HEAD`、公証statusがアプリ/DMGとも`Accepted`であることを確認する。個人の絶対パス、
submission ID、公証response/log、dSYM、entitlements、xcarchive、notary用zipをGitHubへuploadしない。

### 2. tagを固定してDraftを作る

既存tagは移動・再利用しない。annotated tagを成果物のsource commitへ作成してpushしたあと、
公開assetを明示した2ファイルだけに限定してDraftを作る。globは使わない。

```bash
set -euo pipefail
VERSION=$(awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)
TAG="v$VERSION"
COMMIT=$(git rev-parse HEAD)
DMG="dist/AIUsage-$VERSION.dmg"
CHECKSUM="$DMG.sha256"
NOTES_FILE=/absolute/private/release-notes.md

test ! -e "dist/unnotarized/AIUsage-$VERSION-UNNOTARIZED.dmg"
(cd dist && shasum -a 256 -c "$(basename "$CHECKSUM")")
git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1 && exit 1
git tag -a "$TAG" "$COMMIT" -m "AI Usage $VERSION"
git push origin "$TAG"

gh release create "$TAG" \
  --draft \
  --verify-tag \
  --title "AI Usage $VERSION" \
  --notes-file "$NOTES_FILE" \
  "$DMG" \
  "$CHECKSUM"
```

release noteの内容は公開情報になる。`/Users/...`などの個人パス、内部URL、submission ID、
`provenance.json`や非公開logの内容がないことをupload前に確認する。

### 3. Draftを検査して手動Publishする

workflowはdefault branchからだけ起動する。tagがannotated tagでdefault branch履歴上にあること、tagと
`MARKETING_VERSION`の一致、非prereleaseのDraftであること、assetがDMGと`.sha256`の2つだけであること、
SHA-256とGitHub側digestを検査する。検査してもDraftは公開・変更されない。

```bash
gh workflow run release.yml --ref "$DEFAULT_BRANCH" -f tag="$TAG"
```

Actions画面で`Validate GitHub Release Draft`が成功したあと、別の承認者が次を再確認する。

- tagのcommitと非公開provenanceのcommitが一致する
- 対象commitのCIが成功している
- release noteに内部情報がない
- 添付assetが`AIUsage-<version>.dmg`と同名`.sha256`だけである
- ローカルとDraftからdownloadしたDMGのSHA-256が一致する

承認者がGitHub ReleasesのDraft画面から**Publish release**を手動実行する。CLIやworkflowによる自動Publishを
標準手順にしない。公開後は次でimmutable状態とGitHub release attestationを確認する。

```bash
gh release view "$TAG" --json tagName,isDraft,isImmutable,assets
gh release verify "$TAG"
```

GitHubが自動表示するsource archiveを除き、手動添付assetはDMGと`.sha256`だけにする。公開後は
`gh release upload --clobber`、asset削除・再upload、tag移動を行わない。誤りや事故があれば既存assetを
差し替えず、配布停止を告知して新しいversion/build、tag、Draftで修正版を公開する。

### 4. 署名済みappcastを生成してCloudflareへ反映する

Draftや変更可能なassetをfeedへ載せない。Releaseの手動Publish後に`isDraft=false`、
`isImmutable=true`とattestationを確認してから、AI Usage repositoryで次を実行する。

```bash
set -euo pipefail
PROFILE_REPO=/absolute/path/to/profile

./scripts/bootstrap-sparkle-tools.sh
./scripts/prepare-appcast.sh \
  --repository moritouch/ai-usage \
  --tag "$TAG" \
  --output "$PROFILE_REPO/public/ai-usage/appcast.xml"
```

`PROFILE_REPO`はmoritouchのCloudflare profile repositoryの絶対パスを指定する。
`prepare-appcast.sh`は公開済みnon-prerelease・immutable Release、GitHubとローカル`dist/`にある
DMG／`.sha256`、公証・Gatekeeper判定、KeychainのSparkle鍵と`App/Info.plist`の公開鍵を照合する。
既存appcastの履歴を保持し、deltaを生成せず、すべての検証に成功した場合だけ出力をatomicに置き換える。
出力後にXMLを手編集しない。

profile repository側の変更内容に、想定したtagのenclosure URLと署名以外の差分が混ざっていないことを
reviewしてcommit/pushし、対象Cloudflare accountが`moritouch`であることを確認してdeployする。

```bash
cd "$PROFILE_REPO"
pnpm run cloudflare:verify-account
NEXT_PUBLIC_AI_USAGE_GITHUB_REPOSITORY=moritouch/ai-usage \
NEXT_PUBLIC_AI_USAGE_LATEST_VERSION="${TAG#v}" \
  pnpm run deploy
```

deploy後は紹介ページ、repository導線、DMGの直接download導線、feedのContent-Typeと署名をproductionで
確認する。download先は同じimmutable GitHub Releaseの公証済みDMGでなければならない。

```bash
set -euo pipefail
SPARKLE_SIGN_UPDATE=/absolute/path/to/ai-usage/build/sparkle-tools/2.9.6/bin/sign_update
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT

curl --fail --show-error --silent --location \
  https://moritouch.com/ai-usage/appcast.xml \
  --output "$VERIFY_DIR/appcast.xml"
xmllint --noout "$VERIFY_DIR/appcast.xml"
"$SPARKLE_SIGN_UPDATE" \
  --account jp.co.forestx.aiusage \
  --verify "$VERIFY_DIR/appcast.xml"
curl --fail --show-error --silent --location \
  https://moritouch.com/ai-usage >/dev/null
```

feed公開が失敗した場合はGitHub Releaseのassetを変更せず、直前の正しく署名されたappcastへ戻してから
Cloudflareを再deployする。新しいDMGが必要な問題は新version/build、tag、Releaseとして修正する。

参考: [GitHubの手動workflow実行](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)、
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)、
[`gh release create`](https://cli.github.com/manual/gh_release_create)、
[Sparkleの更新公開手順](https://sparkle-project.org/documentation/publishing/)。

## 公開・更新・緊急時の運用

`0.1.9`（build `11`）はSparkleを初めて含むbootstrap版である。それ以前の利用者には、
紹介ページから公証済み`0.1.9` DMGを取得し、アプリを終了して`/Applications`の旧版を手動で
置き換えてもらう。Sparkleを持たない旧版に対してappcastだけで更新を配ることはできない。
`0.1.9`の配布開始前に、項目が空でも正しく署名されたappcastが固定URLからHTTP 200とXMLで返り、
`0.1.9`の手動確認がエラーではなく「最新版です」で完了することを確認する。

最初の実更新E2Eは`0.1.9`をインストールした検証環境から`0.1.10`へ行う。`0.1.10`の
version/buildを上げ、公証済みDMGをimmutable GitHub Releaseとして公開し、上記手順でappcastを
Cloudflareへ反映したあと、設定の「アップデートを確認…」から検出、download、署名検証、置換、
再起動、version/build、Widgetの再登録まで確認する。`0.1.9`自身の「最新版です」という結果は
実更新E2Eの代わりにならない。

以後の利用者は設定から自動確認を有効にするか、手動確認ボタンで更新する。公開前に署名担当者とは
別の承認者が、release記録、公証status、最終DMGのハッシュ、Gatekeeper判定、release note、
appcast enclosureと署名を確認し、対象version/buildと承認結果を記録する。承認前のDMGや公証なしDMG、
Draft ReleaseのURLをappcastへ置かない。

直前の正常版DMG、`.sha256`、release記録、dSYMはアクセス制御された保管先へimmutableに保持する。
同名ファイルを差し替えず、保持期限とサポート対象を決める。公開先に旧版を残す場合は、既知の
脆弱性を含め利用可否を明示する。

問題発生時は新versionの配布を停止し、影響範囲とデータ互換性を確認する。rollbackが安全なら、
保管済みの直前正常版を元のハッシュのまま再案内し、再圧縮・再署名による差し替えはしない。
利用者へ対象version、回避策、復旧状況を通知し、原因修正は新しいversion/buildとして再リリースする。

Developer ID秘密鍵や公証資格情報の漏えいが疑われる場合は直ちにリリースと配布を停止する。
Account Holderを含む担当者がApple Developer側で証明書を失効し、App用パスワード、Keychain profile、
CI等の関連secretを無効化・更新する。署名履歴と公開済みartifactを調査し、信頼できるsourceと新しい
証明書から再build・再公証する。悪用の可能性がある場合は影響を受ける利用者へ通知する。

## 公証なしの検証用ビルド

通常リリースの代替ではない。2つの明示引数が揃わない限り実行されず、旧
`SKIP_NOTARIZE` 環境変数は拒否される。

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/release.sh --unnotarized --confirm-unnotarized
```

出力は `dist/unnotarized/AIUsage-<version>-UNNOTARIZED.dmg` に隔離される。
Gatekeeperで拒否される前提のローカル検証物であり、利用者への配布・公開・正規DMGへの
改名を行わない。
