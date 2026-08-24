# リリース手順

App Store外でDeveloper IDによる直接配布を行う。通常のリリースはアプリとDMGを公証し、
両方にチケットをステープルしてからGatekeeper判定まで確認する。

正規の紹介ページは `https://moritouch.com/ai-usage`、Sparkle feedは
`https://moritouch.com/ai-usage/appcast.xml` とし、moritouchのCloudflare配信を正本にする。
公開GitHub Releaseはsource、同じDMGとSHA-256、固定tag、immutable attestationの配布証跡として使う。
一般利用者向けの正規download、appcast、MIT LicenseはCloudflare Workers Static Assetsから配信する。

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
version/build、Team IDがrelease記録と一致することをrelease operatorが再確認する。複数のmaintainerが
いる場合は署名担当者と承認者を分け、個人運用では同じownerが別の確認工程として記録する。
さらにFinderから最終DMGを通常どおり開き、アイコン表示、案内背景、`AI Usage.app`と`Applications`の
位置、ドラッグ矢印、日英の初回設定案内が読めることを実画面で確認する。Finderを既存タブで開く設定や
隠し項目表示は周囲の余白・項目を変えるため、DMGが指定する800×500の内容領域を基準に確認する。

## 公開GitHub Releaseで成果物を確定する

Git worktree、公開GitHub repository、remote、default branchのどれかが未準備ならRelease作業を開始しない。
この手順と`.github/workflows/release.yml`をdefault branchへ取り込み、remote上のcommitとCIを確認してから進む。
workflow内のrepository名やdefault branchは、固定値ではなく実際のrepository contextから取得する。

Apple署名・公証の正本は管理下Macで実行する`./scripts/release.sh`である。Developer ID秘密鍵、`.p8`、
App用パスワード、notary profileをGitHub Actionsのrepository/environment secretへ登録しない。
`release.yml`は`workflow_dispatch`だけを受け付ける。GitHubがDraft Releaseをpush権限のあるtokenにだけ
公開するため、2つのjobには短命な`GITHUB_TOKEN`の`contents: write`が必要になる。最初のjobはGETだけで
Draftを検査する。承認後のjobもrepositoryをcheckoutせず再検査し、最後にReleaseの`draft`を`false`へ
変えるPATCHを1回だけ実行する。Draft作成、asset upload、Apple署名・公証はworkflowで行わない。

### 初回のGitHub設定

1. repository rootへMITの`LICENSE`を置き、履歴と配布対象に秘密情報や個人固有値がないことを確認する。
2. default branchと`v*` tagをrulesetまたはbranch/tag protectionで保護する。tagを再利用せず、
   CI、annotated tag、Release承認を必須にする。
3. Repository SettingsのReleasesで**release immutability**を有効にする。これは有効化後にPublishする
   Releaseだけへ適用されるため、最初のPublish前に設定する。
4. `release-publish` Environmentを作り、required reviewerを設定する。個人運用で同じownerが起動と承認を
   行う場合はself-reviewを許可する。release immutabilityを確認してworkflowの`publish` checkboxを入れ、
   Environmentでも承認することで2回の明示確認にする。
   別のmaintainerを追加した場合はPrevent self-reviewを有効にして役割を分離する。
5. ActionsへApple関連secretを作らない。Draft閲覧とPublishだけにjob-level `contents: write`を与え、
   repositoryをcheckoutせず、外部Actionも使わない。
6. Dependabot alerts、secret scanning、push protection、Private Vulnerability Reportingを有効にする。
7. GitHub Pagesを過去に公開していた場合はSettings > Pagesからunpublishし、Cloudflareの紹介ページと
   appcastだけを正規配信面にする。

通常の`GITHUB_TOKEN`にはrepository administrationのread権限を追加できないため、workflowからrelease
immutability設定そのものは照会しない。広い長期PATをActionsへ保存する代わりに、起動時の`publish`
checkboxとEnvironment承認時にownerが設定を確認する。Publish jobは公開後のReleaseが実際に
`immutable=true`であることとattestationを必ず検証する。

GitHubのimmutable releaseはPublish後のtag移動・削除とasset変更・削除を防ぎ、確定時のtag、commit、
assetsに対するattestationを生成する。これはGitHub上の公開成果物集合の証跡であり、管理下MacでのApple
build provenanceの代替ではない。DraftはPublish前なら変更可能なので、asset検査をすべて終えてからPublishする。

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
Release assetを明示した2ファイルだけに限定してDraftを作る。globは使わない。

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

Draftのrelease noteはrepositoryへのwrite権限を持つユーザーだけが閲覧できるが、Publish後は一般公開される。
`/Users/...`などの個人パス、submission ID、`provenance.json`や非公開logの内容がないことを
upload前に確認する。

### 3. Draftを検査し、Actions上で承認してPublishする

workflowはdefault branchからだけ起動する。tagがannotated tagでdefault branch履歴上にあること、tagと
`MARKETING_VERSION`の一致、非prereleaseのDraftであること、assetがDMGと`.sha256`の2つだけであること、
SHA-256とGitHub側digestを最初のjobで検査する。`publish=true`の場合も、検査が成功するまで承認待ちへ進まない。

```bash
gh workflow run release.yml \
  --ref "$DEFAULT_BRANCH" \
  -f tag="$TAG" \
  -f publish=true
```

Actions画面で`Validate draft metadata and release assets`が成功すると、`release-publish` Environmentの
承認待ちになる。承認者は次を再確認する。

- tagのcommitと非公開provenanceのcommitが一致する
- 対象commitのCIが成功している
- release noteに内部情報がない
- 添付assetが`AIUsage-<version>.dmg`と同名`.sha256`だけである
- ローカルとDraftからdownloadしたDMGのSHA-256が一致する
- Repository Settingsでrelease immutabilityが有効なままである

workflow runの**Review deployments**から`release-publish`を選び、**Approve and deploy**を押す。
承認後のjobはtag、Draft metadata、asset ID・名前・サイズ・digest、downloadしたDMGのSHA-256をもう一度
検査する。最初の検査後に内容が変わっていればPublishせず停止し、一致した場合だけDraftをPublishする。
Publish後は`immutable=true`とGitHub release attestation、両assetのattestationまで検証する。
成功runを再実行せず、やり直す場合は新しい`workflow_dispatch`として開始する。

公開Releaseとassetは一般利用者もGitHubから取得できる。アプリ自身はGitHub APIやReleaseを参照せず、
GitHub tokenも持たない。Sparkleの正規更新経路は引き続きCloudflare上のappcastと固定version assetである。

```bash
gh release view "$TAG" --json tagName,isDraft,isImmutable,assets
gh release verify "$TAG"
gh release verify-asset "$TAG" "dist/AIUsage-${TAG#v}.dmg"
gh release verify-asset "$TAG" "dist/AIUsage-${TAG#v}.dmg.sha256"
```

GitHubが自動表示するsource archiveを除き、手動添付assetはDMGと`.sha256`だけにする。Publish後は
`gh release upload --clobber`、asset削除・再upload、tag移動を行わない。誤りや事故があれば既存assetを
差し替えず、配布停止を告知して新しいversion/build、tag、Draftで修正版を公開する。

### 4. 署名済みappcastを生成してCloudflareへ反映する

Draftや変更可能なassetをfeedへ載せない。承認付きworkflowのPublish後に`isDraft=false`、
`isImmutable=true`とattestationを確認してから、AI Usage repositoryで次を実行する。

```bash
set -euo pipefail
PROFILE_REPO=/absolute/path/to/profile
PUBLIC_ASSETS_ROOT="$PROFILE_REPO/public/ai-usage/releases"

mkdir -p "$PUBLIC_ASSETS_ROOT"

./scripts/bootstrap-sparkle-tools.sh
./scripts/prepare-appcast.sh \
  --repository moritouch/ai-usage \
  --tag "$TAG" \
  --public-assets-root "$PUBLIC_ASSETS_ROOT" \
  --output "$PROFILE_REPO/public/ai-usage/appcast.xml"
```

`PROFILE_REPO`はmoritouchのCloudflare profile repositoryの絶対パスを指定する。
`prepare-appcast.sh`はPublish済みnon-prerelease・immutableの公開Release、GitHubとローカル`dist/`に
あるDMG／`.sha256`、公証・Gatekeeper判定、KeychainのSparkle鍵と`App/Info.plist`の公開鍵を照合する。
25 MiB未満を確認し、`public/ai-usage/releases/$TAG/`へ2 assetをatomicに配置する。同じtagの既存directoryは
2 fileがbyte一致する場合だけ再利用し、差し替えを拒否する。既存appcastの履歴を保持し、deltaを生成せず、
すべての検証に成功した場合だけ出力をatomicに置き換える。出力後にXMLを手編集しない。

profile repository側の変更内容に、想定したtagのenclosure URLと署名以外の差分が混ざっていないことを
reviewしてcommit/pushし、対象Cloudflare accountが`moritouch`であることを確認してdeployする。

```bash
cd "$PROFILE_REPO"
pnpm run cloudflare:verify-account
NEXT_PUBLIC_AI_USAGE_LATEST_VERSION="${TAG#v}" \
  pnpm run deploy
```

deploy後は紹介ページ、DMGとSHA-256の直接download導線、Range応答、feedのContent-Typeと署名を
productionで確認する。download先は検証済みimmutable Releaseとbyte一致する公証済みDMGでなければならない。

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
curl --fail --show-error --silent --location \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg" \
  --output "$VERIFY_DIR/AIUsage-${TAG#v}.dmg"
curl --fail --show-error --silent --location \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg.sha256" \
  --output "$VERIFY_DIR/AIUsage-${TAG#v}.dmg.sha256"
(cd "$VERIFY_DIR" && shasum -a 256 -c "AIUsage-${TAG#v}.dmg.sha256")
cmp "dist/AIUsage-${TAG#v}.dmg" "$VERIFY_DIR/AIUsage-${TAG#v}.dmg"
curl --fail --show-error --silent \
  --range 0-1023 \
  "https://moritouch.com/ai-usage/releases/$TAG/AIUsage-${TAG#v}.dmg" \
  --output "$VERIFY_DIR/range.bin"
```

feed公開が失敗した場合はimmutable GitHub Releaseのassetを変更せず、直前の正しく署名されたappcastへ戻してから
Cloudflareを再deployする。新しいDMGが必要な問題は新version/build、tag、Releaseとして修正する。

参考: [GitHubの手動workflow実行](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)、
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)、
[`gh release create`](https://cli.github.com/manual/gh_release_create)、
[Sparkleの更新公開手順](https://sparkle-project.org/documentation/publishing/)。

## 公開・更新・緊急時の運用

`0.1.10`（build `12`）はSparkleを含む最初の公開bootstrap版である。それ以前の利用者には、
紹介ページから最新の公証済みDMGを取得し、アプリを終了して`/Applications`の旧版を手動で
置き換えてもらう。Sparkleを持たない旧版に対してappcastだけで更新を配ることはできない。
`0.1.10`の配布開始前に、項目が空でも正しく署名されたappcastが固定URLからHTTP 200とXMLで返り、
`0.1.10`の手動確認がエラーではなく「最新版です」で完了することを確認する。

最初の実更新E2Eは`0.1.10`をインストールした検証環境から`0.1.11`へ行う。`0.1.11`の
version/buildを上げ、公証済みDMGを公開immutable GitHub Releaseとして確定し、上記手順でappcastを
Cloudflareへ反映したあと、設定の「アップデートを確認…」から検出、download、署名検証、置換、
再起動、version/build、Widgetの再登録まで確認する。`0.1.10`自身の「最新版です」という結果は
実更新E2Eの代わりにならない。

以後の利用者は設定から自動確認を有効にするか、手動確認ボタンで更新する。公開前にrelease operatorが、
release記録、公証status、最終DMGのハッシュ、Gatekeeper判定、release note、appcast enclosureと署名を
確認し、対象version/buildと承認結果を記録する。複数のmaintainerがいる場合は署名担当者と承認者を分け、
個人運用では同じownerが二段階で確認する。承認前のDMGや公証なしDMG、
Draft ReleaseやGitHub Release assetのURLをappcastへ置かない。

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
