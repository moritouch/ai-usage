#!/bin/bash
# 配布用ビルド: アーカイブ → Developer ID 署名 → DMG → 公証 → ステープル。
#
#   ./scripts/release.sh --check
#   ./scripts/release.sh
#   ./scripts/release.sh --unnotarized --confirm-unnotarized
#
# 公証なしの成果物は明示確認を要求し、正規配布物とは別の場所・名前に出力する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT_NAME="AIUsage"          # プロジェクト / スキーム / アーカイブ名
APP_NAME="AI Usage"             # 成果物の .app 名
APP_BUNDLE_ID="jp.co.forestx.aiusage"
WIDGET_BUNDLE_ID="jp.co.forestx.aiusage.widget"
DMG_NAME="AIUsage"              # 配布ファイル名（空白を含めない）
VOLUME_NAME="AI Usage"
TEAM_ID="WTKUV8PPM7"
NOTARY_PROFILE="${NOTARY_PROFILE:-AIUsage}"
SPARKLE_VERSION="2.9.6"
SPARKLE_FEED_URL="https://moritouch.com/ai-usage/appcast.xml"
SPARKLE_PUBLIC_KEY="rUEpVqbT7U1FSjjuxv3WyP4Fqd1WFOqk/71V71fKKs0="
PACKAGE_RESOLVED="$ROOT/AIUsage.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SOURCE_PACKAGES_DIR="$ROOT/build/SourcePackages"
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/$PROJECT_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_SETTINGS="$ROOT/packaging/dmg/settings.py"
DMG_REQUIREMENTS="$ROOT/packaging/dmg/requirements.txt"
DMG_BACKGROUND_RENDERER="$ROOT/scripts/make-dmg-background.swift"
DMGBUILD_PYTHON="${DMGBUILD_PYTHON:-$ROOT/build/release-tools/venv/bin/python}"
DMGBUILD_STAMP="$ROOT/build/release-tools/toolchain-stamp.txt"
EXPECTED_DMGBUILD_VERSION="1.6.7"
EXPECTED_DS_STORE_VERSION="1.3.3"
EXPECTED_MAC_ALIAS_VERSION="2.2.3"
RECORD_ROOT="${RELEASE_RECORD_DIR:-$ROOT/build/release-records}"
RELEASE_LOCK_DIR="$ROOT/build/release.lock"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
fail()  { printf '\033[31m%s\033[0m\n' "$1" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/release.sh --check
      公証済み直接配布に必要なツール、証明書、資格情報を確認する（変更なし）。

  ./scripts/release.sh
      Developer ID 署名、アプリ/DMG公証、ステープル、最終検証まで実行する。

  ./scripts/release.sh --unnotarized --confirm-unnotarized
      公証を明示的に省略する。成果物は dist/unnotarized/ の
      *-UNNOTARIZED.dmg に隔離され、正規配布には使用できない。

  ./scripts/release.sh --help
      このヘルプを表示する。

Unknown options are rejected. The legacy SKIP_NOTARIZE environment variable is rejected.
USAGE
}

MODE="release"
UNNOTARIZED=0
case "$#:$*" in
  "0:")
    ;;
  "1:--check")
    MODE="check"
    ;;
  "1:--help"|"1:-h")
    usage
    exit 0
    ;;
  "2:--unnotarized --confirm-unnotarized")
    UNNOTARIZED=1
    ;;
  *)
    fail "不明または不完全な引数です。"
    usage >&2
    exit 2
    ;;
esac

if [ -n "${SKIP_NOTARIZE+x}" ]; then
  fail "SKIP_NOTARIZE は安全上の理由で廃止しました。"
  fail "必要な場合だけ --unnotarized --confirm-unnotarized を明示してください。"
  exit 2
fi

VERSION=$(/usr/bin/awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)
BUILD_NUMBER=$(/usr/bin/awk '$1 == "CURRENT_PROJECT_VERSION:" {gsub(/"/, "", $2); print $2; exit}' project.yml)

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z]+)*([-][0-9A-Za-z.-]+)?$ ]]; then
  fail "project.yml の MARKETING_VERSION が不正です: ${VERSION:-<empty>}"
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  fail "project.yml の CURRENT_PROJECT_VERSION が不正です: ${BUILD_NUMBER:-<empty>}"
  exit 1
fi

if [ "$UNNOTARIZED" -eq 1 ]; then
  RELEASE_MODE="unnotarized"
  FINAL_DMG="$ROOT/dist/unnotarized/$DMG_NAME-$VERSION-UNNOTARIZED.dmg"
else
  RELEASE_MODE="notarized"
  FINAL_DMG="$ROOT/dist/$DMG_NAME-$VERSION.dmg"
fi
FINAL_DMG_HASH_FILE="$FINAL_DMG.sha256"
DMG_HASH_FILE="$FINAL_DMG_HASH_FILE"

# ---------- 署名・事前確認 ----------
signing_identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -v team="($TEAM_ID)" \
        'index($0, "Developer ID Application") && index($0, team) && !found { print $2; found=1 }'
}

signing_identity_lines() {
  security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -v team="($TEAM_ID)" \
        'index($0, "Developer ID Application") && index($0, team)'
}

have_signing_id() {
  [ -n "$(signing_identity_hash)" ]
}

have_notary_profile() {
  xcrun notarytool history \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >/dev/null 2>&1
}

find_repository_secret() {
  find "$ROOT" \
    \( -path "$ROOT/.git" -o -path "$ROOT/build" -o -path "$ROOT/dist" \
       -o -path "$ROOT/DerivedData" -o -path '*/xcuserdata' \) -prune -o \
    -type f \( -name '*.p8' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' \) \
    -print -quit
}

EXPECTED_GIT_COMMIT=""
GIT_SOURCE_COMMIT=""
GIT_SOURCE_STATE="unavailable"
GIT_SOURCE_ERROR=""
EXPECTED_DEVELOPER_DIR=""
EFFECTIVE_DEVELOPER_DIR=""
EFFECTIVE_XCODE_APP=""
EFFECTIVE_XCODEBUILD_PATH=""
XCODE_RELEASE_CHANNEL="unknown"
XCODE_TOOLCHAIN_ERROR=""
DEVELOPER_DIRECTORY_SOURCE="xcode-select"

inspect_git_source() {
  local git_root
  local git_root_physical
  local root_physical
  local status_output

  GIT_SOURCE_COMMIT=""
  GIT_SOURCE_STATE="unavailable"
  GIT_SOURCE_ERROR=""

  if ! command -v git >/dev/null 2>&1; then
    GIT_SOURCE_ERROR="gitコマンドがありません"
    return 1
  fi
  if [ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null || printf 'false')" != "true" ]; then
    GIT_SOURCE_ERROR="project rootがGit worktreeではありません"
    return 1
  fi
  if ! git_root=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null); then
    GIT_SOURCE_ERROR="Git repository rootを取得できません"
    return 1
  fi
  if ! git_root_physical=$(cd "$git_root" 2>/dev/null && pwd -P); then
    GIT_SOURCE_ERROR="Git repository rootを解決できません"
    return 1
  fi
  root_physical=$(cd "$ROOT" && pwd -P)
  if [ "$git_root_physical" != "$root_physical" ]; then
    GIT_SOURCE_ERROR="project rootとGit repository rootが一致しません"
    return 1
  fi
  if ! GIT_SOURCE_COMMIT=$(git -C "$ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
    GIT_SOURCE_COMMIT=""
    GIT_SOURCE_ERROR="有効なHEAD commitがありません"
    return 1
  fi
  if [[ ! "$GIT_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    GIT_SOURCE_ERROR="HEAD commit IDがGitHub互換の40桁SHAではありません"
    return 1
  fi
  if ! status_output=$(git -C "$ROOT" status --porcelain --untracked-files=all 2>/dev/null); then
    GIT_SOURCE_ERROR="Git worktree状態を取得できません"
    return 1
  fi
  if [ -n "$status_output" ]; then
    GIT_SOURCE_STATE="dirty"
    GIT_SOURCE_ERROR="Git worktreeに未commitまたは未追跡の変更があります"
    return 1
  fi

  GIT_SOURCE_STATE="clean"
  return 0
}

inspect_xcode_toolchain() {
  local developer_dir
  local xcodebuild_path

  EFFECTIVE_DEVELOPER_DIR=""
  EFFECTIVE_XCODE_APP=""
  EFFECTIVE_XCODEBUILD_PATH=""
  XCODE_RELEASE_CHANNEL="unknown"
  XCODE_TOOLCHAIN_ERROR=""
  DEVELOPER_DIRECTORY_SOURCE="xcode-select"

  if [ -n "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIRECTORY_SOURCE="DEVELOPER_DIR"
  fi
  if ! xcodebuild_path=$(xcrun --find xcodebuild 2>/dev/null); then
    XCODE_TOOLCHAIN_ERROR="実効Xcodeのxcodebuildを解決できません"
    return 1
  fi
  case "$xcodebuild_path" in
    */Contents/Developer/usr/bin/xcodebuild)
      developer_dir=${xcodebuild_path%/usr/bin/xcodebuild}
      ;;
    *)
      XCODE_TOOLCHAIN_ERROR="xcodebuildがXcode.app内にありません: $xcodebuild_path"
      return 1
      ;;
  esac
  if ! EFFECTIVE_DEVELOPER_DIR=$(cd "$developer_dir" 2>/dev/null && pwd -P); then
    XCODE_TOOLCHAIN_ERROR="実効Developer directoryを解決できません: $developer_dir"
    return 1
  fi
  EFFECTIVE_XCODE_APP=${EFFECTIVE_DEVELOPER_DIR%/Contents/Developer}
  EFFECTIVE_XCODEBUILD_PATH="$EFFECTIVE_DEVELOPER_DIR/usr/bin/xcodebuild"
  if [ ! -f "$EFFECTIVE_XCODE_APP/Contents/Info.plist" ]; then
    XCODE_TOOLCHAIN_ERROR="実効Xcode.appのInfo.plistがありません: $EFFECTIVE_XCODE_APP"
    return 1
  fi
  if [ -f "$EFFECTIVE_XCODE_APP/Contents/Resources/BetaVersion.plist" ]; then
    XCODE_RELEASE_CHANNEL="beta"
  else
    XCODE_RELEASE_CHANNEL="stable"
  fi
  return 0
}

check_git_source_checkpoint() {
  local checkpoint=$1
  local checkpoint_error=""

  if inspect_git_source; then
    if [ -z "$EXPECTED_GIT_COMMIT" ]; then
      checkpoint_error="preflight時のsource commitがありません"
    elif [ "$GIT_SOURCE_COMMIT" != "$EXPECTED_GIT_COMMIT" ]; then
      checkpoint_error="HEADがpreflight時のcommitから変わりました"
    else
      return 0
    fi
  else
    checkpoint_error=$GIT_SOURCE_ERROR
  fi

  if [ "$UNNOTARIZED" -eq 1 ]; then
    warn "  [--] $checkpoint のGit source確認: $checkpoint_error"
    return 0
  fi
  fail "$checkpoint のGit source確認に失敗: $checkpoint_error"
  return 1
}

ACTUAL_RELEASE_PYTHON_VERSION=""
ACTUAL_DMGBUILD_VERSION=""
ACTUAL_DS_STORE_VERSION=""
ACTUAL_MAC_ALIAS_VERSION=""
RELEASE_TOOLS_ERROR=""

inspect_release_tools() {
  local details
  local requirements_sha256
  local expected_stamp
  local actual_stamp

  ACTUAL_RELEASE_PYTHON_VERSION=""
  ACTUAL_DMGBUILD_VERSION=""
  ACTUAL_DS_STORE_VERSION=""
  ACTUAL_MAC_ALIAS_VERSION=""
  RELEASE_TOOLS_ERROR=""

  if [ ! -x "$DMGBUILD_PYTHON" ]; then
    RELEASE_TOOLS_ERROR="固定Python環境がありません: $DMGBUILD_PYTHON"
    return 1
  fi
  if [ ! -f "$DMGBUILD_STAMP" ]; then
    RELEASE_TOOLS_ERROR="release tool stampがありません: $DMGBUILD_STAMP"
    return 1
  fi

  if ! details=$("$DMGBUILD_PYTHON" - \
      "$EXPECTED_DMGBUILD_VERSION" \
      "$EXPECTED_DS_STORE_VERSION" \
      "$EXPECTED_MAC_ALIAS_VERSION" <<'PY'
from importlib.metadata import distribution, version
import base64
import hashlib
import platform
import sys

expected = {
    "dmgbuild": sys.argv[1],
    "ds-store": sys.argv[2],
    "mac-alias": sys.argv[3],
}
actual = {name: version(name) for name in expected}
if actual != expected:
    raise SystemExit(f"release tool versions do not match: {actual}")

for name in expected:
    package = distribution(name)
    for entry in package.files or ():
        if entry.hash is None:
            continue
        path = package.locate_file(entry)
        digest = hashlib.new(entry.hash.mode, path.read_bytes()).digest()
        encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
        if encoded != entry.hash.value:
            raise SystemExit(f"release tool integrity check failed: {name}: {entry}")

print("\t".join((
    platform.python_version(),
    actual["dmgbuild"],
    actual["ds-store"],
    actual["mac-alias"],
)))
PY
  ); then
    RELEASE_TOOLS_ERROR="release toolのversionまたはinstalled file integrityが一致しません"
    return 1
  fi

  IFS=$'\t' read -r \
    ACTUAL_RELEASE_PYTHON_VERSION \
    ACTUAL_DMGBUILD_VERSION \
    ACTUAL_DS_STORE_VERSION \
    ACTUAL_MAC_ALIAS_VERSION <<<"$details"
  if [ -z "$ACTUAL_RELEASE_PYTHON_VERSION" ] \
     || [ -z "$ACTUAL_DMGBUILD_VERSION" ] \
     || [ -z "$ACTUAL_DS_STORE_VERSION" ] \
     || [ -z "$ACTUAL_MAC_ALIAS_VERSION" ]; then
    RELEASE_TOOLS_ERROR="release toolの実測versionを取得できません"
    return 1
  fi

  requirements_sha256=$(shasum -a 256 "$DMG_REQUIREMENTS" | /usr/bin/awk '{print $1}')
  expected_stamp=$(printf '%s\n' \
    'schemaVersion=1' \
    "requirementsSha256=$requirements_sha256" \
    "pythonVersion=$ACTUAL_RELEASE_PYTHON_VERSION" \
    "dmgbuildVersion=$ACTUAL_DMGBUILD_VERSION" \
    "dsStoreVersion=$ACTUAL_DS_STORE_VERSION" \
    "macAliasVersion=$ACTUAL_MAC_ALIAS_VERSION")
  actual_stamp=$(cat "$DMGBUILD_STAMP")
  if [ "$actual_stamp" != "$expected_stamp" ]; then
    RELEASE_TOOLS_ERROR="release tool stampが現在のrequirementsとinstalled environmentに一致しません"
    return 1
  fi
  return 0
}

preflight() {
  local ready=0
  local tool
  local secret_path
  local required_tools=(
    /usr/libexec/PlistBuddy awk basename cat chmod codesign cp date dirname ditto diskutil find git hdiutil ln
    jq mkdir mktemp mv otool plutil readlink rm rmdir security sed shasum sips sleep sort spctl tail tr
    xcode-select xcodebuild xcodegen xcrun
  )

  echo "== 配布に必要なもの =="

  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "  [--] 必須コマンドがありません: $tool"
      ready=1
    fi
  done
  if [ "$ready" -eq 0 ]; then
    green "  [ok] 必須コマンド"
  fi

  if [ ! -f "$DMG_SETTINGS" ] || [ ! -f "$DMG_REQUIREMENTS" ] \
     || [ ! -f "$DMG_BACKGROUND_RENDERER" ]; then
    fail "  [--] DMGレイアウト設定または背景rendererがありません"
    ready=1
  elif inspect_release_tools; then
    green "  [ok] dmgbuild $ACTUAL_DMGBUILD_VERSION / ds-store $ACTUAL_DS_STORE_VERSION / mac-alias $ACTUAL_MAC_ALIAS_VERSION"
  else
    fail "  [--] dmgbuild $EXPECTED_DMGBUILD_VERSION の固定環境を検証できません"
    fail "       $RELEASE_TOOLS_ERROR"
    echo "       ./scripts/bootstrap-release-tools.sh を先に実行してください。"
    ready=1
  fi

  if inspect_git_source; then
    EXPECTED_GIT_COMMIT=$GIT_SOURCE_COMMIT
    green "  [ok] Git source: clean HEAD $EXPECTED_GIT_COMMIT"
  elif [ "$UNNOTARIZED" -eq 1 ]; then
    EXPECTED_GIT_COMMIT=$GIT_SOURCE_COMMIT
    warn "  [--] Git source: ${GIT_SOURCE_ERROR}（公証なしローカル検証のみ継続）"
  else
    EXPECTED_GIT_COMMIT=""
    fail "  [--] Git source: $GIT_SOURCE_ERROR"
    fail "       正規releaseはGit repositoryのcleanなHEADからだけ作成できます。"
    ready=1
  fi

  if xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    green "  [ok] notarytool / stapler"
  elif [ "$UNNOTARIZED" -eq 0 ]; then
    fail "  [--] notarytool または stapler が見つかりません"
    ready=1
  else
    warn "  [--] notarytool / stapler なし（明示した公証なしビルドでは未使用）"
  fi

  if have_signing_id; then
    green "  [ok] Team $TEAM_ID の Developer ID Application 証明書"
    signing_identity_lines | sed 's/^/       /'
  else
    fail "  [--] Team $TEAM_ID の Developer ID Application 証明書がありません"
    echo "       Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    ready=1
  fi

  if [ "$UNNOTARIZED" -eq 0 ]; then
    if have_notary_profile; then
      green "  [ok] 公証資格情報（プロファイル: ${NOTARY_PROFILE}）"
    else
      fail "  [--] 公証資格情報を検証できません（資格情報またはネットワークを確認）"
      printf '       xcrun notarytool store-credentials "%s" \\\n' "$NOTARY_PROFILE"
      echo "         --apple-id <Apple ID> --team-id $TEAM_ID"
      echo "       パスワードは安全な対話プロンプトで入力します。"
      ready=1
    fi
  else
    warn "  [--] 公証を明示的に省略するモードです"
  fi

  if inspect_xcode_toolchain && xcodebuild -version >/dev/null 2>&1; then
    EXPECTED_DEVELOPER_DIR=$EFFECTIVE_DEVELOPER_DIR
    green "  [ok] Xcode: $(xcodebuild -version | tr '\n' ' ')"
    echo "       Effective developer directory: $EFFECTIVE_DEVELOPER_DIR ($DEVELOPER_DIRECTORY_SOURCE)"
    echo "       XcodeGen: $(xcodegen --version | tr '\n' ' ')"
    if [ "$XCODE_RELEASE_CHANNEL" = "stable" ]; then
      green "  [ok] stable Xcode distribution"
    elif [ "$UNNOTARIZED" -eq 1 ]; then
      warn "  [--] beta Xcodeを使用中（公証なしローカル検証のみ継続）"
    else
      fail "  [--] beta Xcodeは正規releaseに使用できません: $EFFECTIVE_XCODE_APP"
      fail "       stable XcodeをDEVELOPER_DIRで明示して再実行してください。"
      ready=1
    fi
  else
    fail "  [--] Xcodeを検証できません: ${XCODE_TOOLCHAIN_ERROR:-xcodebuild実行失敗}"
    ready=1
  fi

  secret_path=$(find_repository_secret)
  if [ -n "$secret_path" ]; then
    fail "  [--] リポジトリ内に秘密鍵/証明書アーカイブがあります: $secret_path"
    fail "       リポジトリ外へ移してから実行してください。"
    ready=1
  else
    green "  [ok] リポジトリ内に秘密鍵ファイルなし"
  fi

  if bash "$ROOT/scripts/check-localizations.sh"; then
    green "  [ok] 日英localization catalog"
  else
    fail "  [--] 日英localization catalogの検証に失敗"
    ready=1
  fi

  if [ ! -f "$PACKAGE_RESOLVED" ]; then
    fail "  [--] Swift package lockがありません: $PACKAGE_RESOLVED"
    ready=1
  elif jq -e \
      --arg version "$SPARKLE_VERSION" \
      '(.version == 3)
       and ([.pins[]
             | select(.identity == "sparkle"
                      and .location == "https://github.com/sparkle-project/Sparkle"
                      and .state.version == $version
                      and .state.revision == "ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a")]
            | length == 1)' \
      "$PACKAGE_RESOLVED" >/dev/null; then
    green "  [ok] Sparkle $SPARKLE_VERSION のpackage lock"
  else
    fail "  [--] Sparkle package lockが固定version/revisionと一致しません"
    ready=1
  fi

  if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
    fail "  [--] 同じバージョンの出力が既にあります: $FINAL_DMG"
    fail "       上書きはしません。バージョンを上げるか、既存成果物を退避してください。"
    ready=1
  else
    green "  [ok] 出力先に同一バージョンなし"
  fi

  echo
  if [ "$ready" -eq 0 ]; then
    if [ "$UNNOTARIZED" -eq 1 ]; then
      warn "公証なしビルドの前提が揃っています。正規配布には使用できません。"
    else
      green "すべて揃っています。./scripts/release.sh で公証済み配布物を作れます。"
    fi
  else
    warn "上の問題を解消するまでリリース処理を開始しません。"
  fi
  return "$ready"
}

if [ "$MODE" = "check" ]; then
  if preflight; then
    exit 0
  else
    exit 1
  fi
fi

preflight || exit 1

# ---------- 監査記録 ----------
RUN_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ')-$VERSION-$BUILD_NUMBER-$RELEASE_MODE
RECORD_DIR="$RECORD_ROOT/$RUN_ID"
WORK_DIR="$BUILD_DIR/working/$RUN_ID"
if [ "$UNNOTARIZED" -eq 1 ]; then
  DMG="$WORK_DIR/$DMG_NAME-$VERSION-UNNOTARIZED.dmg"
else
  DMG="$WORK_DIR/$DMG_NAME-$VERSION.dmg"
fi
WORK_DMG_HASH_FILE="$DMG.sha256"
DMG_BACKGROUND="$WORK_DIR/dmg-background.png"
DMG_INPUT_DIR="$RECORD_DIR/dmg-inputs"
DMG_SETTINGS_SNAPSHOT="$DMG_INPUT_DIR/settings.py"
DMG_REQUIREMENTS_SNAPSHOT="$DMG_INPUT_DIR/requirements.txt"
DMG_BACKGROUND_RENDERER_SNAPSHOT="$DMG_INPUT_DIR/make-dmg-background.swift"
DMGBUILD_STAMP_SNAPSHOT="$DMG_INPUT_DIR/toolchain-stamp.txt"
PROVENANCE="$RECORD_DIR/provenance.json"
SOURCE_MANIFEST="$RECORD_DIR/source-sha256.txt"
SOURCE_MANIFEST_AFTER="$RECORD_DIR/source-sha256-after-build.txt"
SOURCE_MANIFEST_BEFORE_DMG="$RECORD_DIR/source-sha256-before-dmg.txt"
SOURCE_MANIFEST_AFTER_DMG="$RECORD_DIR/source-sha256-after-dmg.txt"
DEBUG_SYMBOL_DIR="$RECORD_DIR/debug-symbols"
CURRENT_STEP="record-initialization"
MOUNT_DIR=""
MOUNTED=0
LOCK_HELD=0
RECORD_CREATED=0
ARTIFACTS_PUBLISHED=0

umask 077
mkdir -p "$ROOT/build" "$RECORD_ROOT"

receipt_has_key() {
  plutil -type "$1" "$PROVENANCE" >/dev/null 2>&1
}

receipt_set_string() {
  if receipt_has_key "$1"; then
    plutil -replace "$1" -string "$2" "$PROVENANCE"
  else
    plutil -insert "$1" -string "$2" "$PROVENANCE"
  fi
}

receipt_set_integer() {
  if receipt_has_key "$1"; then
    plutil -replace "$1" -integer "$2" "$PROVENANCE"
  else
    plutil -insert "$1" -integer "$2" "$PROVENANCE"
  fi
}

receipt_add_dictionary() {
  if ! receipt_has_key "$1"; then
    plutil -insert "$1" -dictionary "$PROVENANCE"
  fi
}

cleanup_mount() {
  local cleanup_status=0

  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    if diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 \
       || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
      MOUNTED=0
    else
      warn "DMGを自動ejectできませんでした: $MOUNT_DIR"
      cleanup_status=1
    fi
  fi
  if [ "$MOUNTED" -eq 0 ] && [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
    if ! rmdir "$MOUNT_DIR" >/dev/null 2>&1; then
      warn "一時mount directoryを削除できませんでした: $MOUNT_DIR"
      cleanup_status=1
    fi
  fi
  return "$cleanup_status"
}

cleanup_on_exit() {
  local script_status=$?
  trap - EXIT
  set +e
  if ! cleanup_mount && [ "$script_status" -eq 0 ]; then
    script_status=1
  fi
  if [ "$ARTIFACTS_PUBLISHED" -eq 1 ] && [ "$CURRENT_STEP" != "complete" ]; then
    if [ -e "$FINAL_DMG" ] && ! rm "$FINAL_DMG"; then
      warn "失敗したreleaseの公開DMGを取り除けませんでした: $FINAL_DMG"
      script_status=1
    fi
    if [ -e "$FINAL_DMG_HASH_FILE" ] && ! rm "$FINAL_DMG_HASH_FILE"; then
      warn "失敗したreleaseの公開checksumを取り除けませんでした: $FINAL_DMG_HASH_FILE"
      script_status=1
    fi
    ARTIFACTS_PUBLISHED=0
  fi
  # Bashの展開エラーなどで終了statusが誤って0として渡っても、完了点へ到達していない
  # releaseを成功扱いにしない。途中終了したreceiptは必ずfailedへ閉じる。
  if [ "$RECORD_CREATED" -eq 1 ] && [ -f "$PROVENANCE" ] \
     && [ "$CURRENT_STEP" != "complete" ]; then
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
    receipt_set_string "state" "failed"
    receipt_add_dictionary "failure"
    receipt_set_string "failure.step" "$CURRENT_STEP"
    receipt_set_integer "failure.exitStatus" "$script_status"
    receipt_set_string "failure.recordedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    plutil -convert json -r "$PROVENANCE" >/dev/null 2>&1
    chmod 600 "$PROVENANCE"
    shasum -a 256 "$PROVENANCE" >"$PROVENANCE.sha256"
    chmod 600 "$PROVENANCE.sha256"
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    if rmdir "$RELEASE_LOCK_DIR" >/dev/null 2>&1; then
      LOCK_HELD=0
    else
      warn "release lockを解除できませんでした: $RELEASE_LOCK_DIR"
      if [ "$script_status" -eq 0 ]; then
        script_status=1
      fi
    fi
  fi
  exit "$script_status"
}
trap cleanup_on_exit EXIT

if ! mkdir "$RELEASE_LOCK_DIR" 2>/dev/null; then
  fail "別のreleaseまたはrelease tool準備が実行中です: $RELEASE_LOCK_DIR"
  fail "実行中のprocessがないのに残っている場合だけ、空のlock directoryをrmdirしてください。"
  exit 1
fi
LOCK_HELD=1

# preflight後に別processが先に同versionを公開したraceも、lock取得後に再確認する。
if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
  fail "同じバージョンの出力が既にあります: $FINAL_DMG"
  exit 1
fi
if ! mkdir "$RECORD_DIR"; then
  fail "同名のrelease記録が既にあります: $RECORD_DIR"
  exit 1
fi
RECORD_CREATED=1
mkdir -p "$WORK_DIR"

# macOS 27のplutilは空のJSON objectへ直接insertできないため、XMLでrootを構成してから
# JSONへ変換する。以後のinsert/replaceは非空JSONに対して行う。
plutil -create xml1 "$PROVENANCE"
chmod 600 "$PROVENANCE"
receipt_set_integer "schemaVersion" 1
receipt_set_string "state" "prepared"
receipt_set_string "createdAt" "$RUN_TIMESTAMP"
receipt_add_dictionary "app"
receipt_set_string "app.name" "$APP_NAME"
receipt_set_string "app.bundleId" "$APP_BUNDLE_ID"
receipt_set_string "app.widgetBundleId" "$WIDGET_BUNDLE_ID"
receipt_set_string "app.teamId" "$TEAM_ID"
receipt_set_string "app.marketingVersion" "$VERSION"
receipt_set_string "app.buildNumber" "$BUILD_NUMBER"
receipt_add_dictionary "release"
receipt_set_string "release.mode" "$RELEASE_MODE"
receipt_set_string "release.outputPath" "$FINAL_DMG"
receipt_set_string "release.workingPath" "$DMG"
receipt_set_string "release.notaryProfile" "$NOTARY_PROFILE"
receipt_add_dictionary "source"
receipt_add_dictionary "toolchain"
receipt_add_dictionary "signing"
receipt_add_dictionary "update"
receipt_add_dictionary "artifacts"
receipt_add_dictionary "artifacts.dmgLayout"
receipt_add_dictionary "notarization"
receipt_add_dictionary "notarization.app"
receipt_add_dictionary "notarization.dmg"
receipt_set_string "notarization.app.status" "$([ "$UNNOTARIZED" -eq 1 ] && printf 'skipped-explicitly' || printf 'not-started')"
receipt_set_string "notarization.dmg.status" "$([ "$UNNOTARIZED" -eq 1 ] && printf 'skipped-explicitly' || printf 'not-started')"
plutil -convert json -r "$PROVENANCE"

if ! inspect_xcode_toolchain; then
  fail "receipt作成前にXcodeを検証できません: $XCODE_TOOLCHAIN_ERROR"
  exit 1
fi
if [ -z "$EXPECTED_DEVELOPER_DIR" ] || [ "$EFFECTIVE_DEVELOPER_DIR" != "$EXPECTED_DEVELOPER_DIR" ]; then
  fail "preflight後に実効Developer directoryが変わりました。releaseを中止します。"
  exit 1
fi
if [ "$UNNOTARIZED" -eq 0 ] && [ "$XCODE_RELEASE_CHANNEL" != "stable" ]; then
  fail "receipt作成前にbeta Xcodeを検出しました。releaseを中止します。"
  exit 1
fi

XCODE_PRODUCT_VERSION=$(xcodebuild -version | /usr/bin/awk 'NR == 1 {print $2}')
XCODE_BUILD=$(xcodebuild -version | /usr/bin/awk 'NR == 2 {print $3}')
SDK_VERSION=$(xcodebuild -version -sdk macosx SDKVersion)
SDK_BUILD=$(xcodebuild -version -sdk macosx ProductBuildVersion)
XCODEGEN_VERSION=$(xcodegen --version | tr '\n' ' ')
SIGN_ID=$(signing_identity_hash)

receipt_set_string "toolchain.xcodeProductVersion" "$XCODE_PRODUCT_VERSION"
receipt_set_string "toolchain.xcodeBuild" "$XCODE_BUILD"
receipt_set_string "toolchain.sdkVersion" "$SDK_VERSION"
receipt_set_string "toolchain.sdkBuild" "$SDK_BUILD"
receipt_set_string "toolchain.developerDirectory" "$EFFECTIVE_DEVELOPER_DIR"
receipt_set_string "toolchain.developerDirectorySource" "$DEVELOPER_DIRECTORY_SOURCE"
receipt_set_string "toolchain.xcodeApplication" "$EFFECTIVE_XCODE_APP"
receipt_set_string "toolchain.xcodebuildPath" "$EFFECTIVE_XCODEBUILD_PATH"
receipt_set_string "toolchain.releaseChannel" "$XCODE_RELEASE_CHANNEL"
receipt_set_string "toolchain.xcodegen" "$XCODEGEN_VERSION"
receipt_set_string "signing.preflightDeveloperIdSha1" "$SIGN_ID"

if inspect_git_source; then
  if [ -n "$EXPECTED_GIT_COMMIT" ] && [ "$GIT_SOURCE_COMMIT" != "$EXPECTED_GIT_COMMIT" ]; then
    fail "receipt作成前にHEADが変わりました。releaseを中止します。"
    exit 1
  fi
  receipt_set_string "source.gitCommit" "$GIT_SOURCE_COMMIT"
  receipt_set_string "source.gitState" "clean"
else
  receipt_set_string "source.gitCommit" "${GIT_SOURCE_COMMIT:-unavailable}"
  receipt_set_string "source.gitState" "$GIT_SOURCE_STATE"
  if [ "$UNNOTARIZED" -eq 0 ]; then
    fail "receipt作成前のGit source確認に失敗: $GIT_SOURCE_ERROR"
    exit 1
  fi
  warn "公証なし成果物のGit sourceは${GIT_SOURCE_STATE}です: $GIT_SOURCE_ERROR"
fi

run_logged() {
  local log_path=$1
  local command_status
  shift
  if "$@" >"$log_path" 2>&1; then
    tail -n 20 "$log_path" | sed 's/^/    /'
    return 0
  else
    command_status=$?
    tail -n 80 "$log_path" | sed 's/^/    /' >&2
    return "$command_status"
  fi
}

write_source_manifest() {
  local manifest_path=$1
  local source_file
  local file_hash
  local relative_path

  while IFS= read -r -d '' relative_path; do
    source_file="$ROOT/$relative_path"
    file_hash=$(shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')
    printf '%s  %s\n' "$file_hash" "$relative_path"
  done < <(git -C "$ROOT" ls-files -z) | LC_ALL=C sort >"$manifest_path"
  chmod 600 "$manifest_path"
  shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}'
}

write_tree_manifest() {
  local tree_root=$1
  local manifest_path=$2
  local source_file
  local file_hash
  local relative_path

  while IFS= read -r -d '' source_file; do
    file_hash=$(shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')
    relative_path=${source_file#"$tree_root/"}
    printf '%s  %s\n' "$file_hash" "$relative_path"
  done < <(find "$tree_root" -type f -print0) | LC_ALL=C sort >"$manifest_path"
  chmod 600 "$manifest_path"
  shasum -a 256 "$manifest_path" | /usr/bin/awk '{print $1}'
}

source_manifest_hash_for() {
  local manifest_path=$1
  local relative_path=$2
  /usr/bin/awk -v path="$relative_path" '
    substr($0, 67) == path { value=substr($0, 1, 64); count++ }
    END {
      if (count == 1) print value
      else exit 1
    }
  ' "$manifest_path"
}

snapshot_dmg_input() {
  local source_path=$1
  local snapshot_path=$2
  local relative_path=${source_path#"$ROOT/"}
  local expected_hash
  local snapshot_hash

  expected_hash=$(source_manifest_hash_for "$SOURCE_MANIFEST_AFTER" "$relative_path") \
    || { fail "source manifestにDMG入力がありません: $relative_path"; return 1; }
  if [ "$UNNOTARIZED" -eq 0 ]; then
    git -C "$ROOT" show "$EXPECTED_GIT_COMMIT:$relative_path" >"$snapshot_path"
  else
    cp "$source_path" "$snapshot_path"
  fi
  snapshot_hash=$(shasum -a 256 "$snapshot_path" | /usr/bin/awk '{print $1}')
  [ "$snapshot_hash" = "$expected_hash" ] \
    || { fail "DMG入力snapshotがbuild時sourceと一致しません: $relative_path"; return 1; }
  chmod 600 "$snapshot_path"
}

snapshot_dmg_inputs() {
  mkdir "$DMG_INPUT_DIR"
  snapshot_dmg_input "$DMG_SETTINGS" "$DMG_SETTINGS_SNAPSHOT"
  snapshot_dmg_input "$DMG_REQUIREMENTS" "$DMG_REQUIREMENTS_SNAPSHOT"
  snapshot_dmg_input "$DMG_BACKGROUND_RENDERER" "$DMG_BACKGROUND_RENDERER_SNAPSHOT"
  cp "$DMGBUILD_STAMP" "$DMGBUILD_STAMP_SNAPSHOT"
  chmod 600 "$DMGBUILD_STAMP_SNAPSHOT"
}

plist_value() {
  plutil -extract "$1" raw "$2"
}

codesign_team_id() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" {value=$2} END {print value}'
}

codesign_cdhash() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk -F= '$1 == "CDHash" {value=$2} END {print value}'
}

codesign_has_hardened_runtime() {
  codesign -dvv "$1" 2>&1 \
    | /usr/bin/awk 'index($0, "flags=") && index($0, "runtime") {found=1} END {exit found ? 0 : 1}'
}

entitlement_value() {
  local key_path=$1
  local plist_path=$2
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null
}

verify_exported_app() {
  local app_plist="$APP/Contents/Info.plist"
  local widget="$APP/Contents/PlugIns/AIUsageWidget.appex"
  local widget_plist="$widget/Contents/Info.plist"
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  local sparkle_plist="$sparkle/Versions/Current/Resources/Info.plist"
  local notices="$APP/Contents/Resources/Third-Party-Notices.txt"
  local app_entitlements="$RECORD_DIR/exported-app-entitlements.plist"
  local widget_entitlements="$RECORD_DIR/exported-widget-entitlements.plist"
  local app_entitlements_stderr="$RECORD_DIR/exported-app-entitlements.stderr.log"
  local widget_entitlements_stderr="$RECORD_DIR/exported-widget-entitlements.stderr.log"
  local app_cert_prefix="$RECORD_DIR/exported-app-signing-cert-"
  local widget_cert_prefix="$RECORD_DIR/exported-widget-signing-cert-"
  local app_cert_sha1
  local widget_cert_sha1
  local expected_app_group="$TEAM_ID.$APP_BUNDLE_ID"
  local actual

  [ -d "$APP" ] || { fail "書き出されたアプリがありません: $APP"; return 1; }
  [ -d "$widget" ] || { fail "Widget拡張がありません: $widget"; return 1; }
  [ -d "$sparkle" ] || { fail "Sparkle.frameworkがアプリにありません"; return 1; }
  [ -f "$sparkle_plist" ] || { fail "Sparkle.frameworkのInfo.plistがありません"; return 1; }
  [ -s "$notices" ] || { fail "ライセンス・third-party noticesがアプリにありません"; return 1; }
  [ "$(shasum -a 256 "$notices" | /usr/bin/awk '{print $1}')" \
    = "$(shasum -a 256 "$ROOT/Resources/Third-Party-Notices.txt" | /usr/bin/awk '{print $1}')" ] \
    || { fail "アプリ内のライセンス・third-party noticesがソースと一致しません"; return 1; }
  [ ! -e "$widget/Contents/Frameworks/Sparkle.framework" ] \
    || { fail "WidgetへSparkle.frameworkを含めてはいけません"; return 1; }

  local localized_bundle
  local language_code
  local strings_file
  for localized_bundle in "$APP" "$widget"; do
    for language_code in en ja; do
      strings_file="$localized_bundle/Contents/Resources/$language_code.lproj/Localizable.strings"
      [ -f "$strings_file" ] \
        || { fail "$localized_bundle に $language_code localizationがありません"; return 1; }
      plutil -lint "$strings_file" >/dev/null \
        || { fail "$strings_file を検証できません"; return 1; }
    done
  done

  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
  codesign --verify --strict --verbose=2 "$widget" 2>&1 | sed 's/^/    /'
  codesign --verify --deep --strict --verbose=2 "$sparkle" 2>&1 | sed 's/^/    /'

  codesign -d --extract-certificates="$app_cert_prefix" "$APP" >/dev/null 2>&1
  codesign -d --extract-certificates="$widget_cert_prefix" "$widget" >/dev/null 2>&1
  [ -f "${app_cert_prefix}0" ] || { fail "アプリの署名証明書を抽出できません"; return 1; }
  [ -f "${widget_cert_prefix}0" ] || { fail "Widgetの署名証明書を抽出できません"; return 1; }
  find "$RECORD_DIR" -maxdepth 1 -type f \
    \( -name 'exported-app-signing-cert-*' -o -name 'exported-widget-signing-cert-*' \) \
    -exec chmod 600 {} +
  app_cert_sha1=$(shasum -a 1 "${app_cert_prefix}0" | /usr/bin/awk '{print toupper($1)}')
  widget_cert_sha1=$(shasum -a 1 "${widget_cert_prefix}0" | /usr/bin/awk '{print toupper($1)}')
  signing_identity_lines | /usr/bin/awk -v hash="$app_cert_sha1" \
    '$2 == hash {found=1} END {exit found ? 0 : 1}' \
    || { fail "実際のアプリ署名証明書がTeam ${TEAM_ID}の利用可能identityと一致しません"; return 1; }
  [ "$widget_cert_sha1" = "$app_cert_sha1" ] \
    || { fail "アプリとWidgetの署名証明書が一致しません"; return 1; }
  receipt_set_string "signing.developerIdSha1" "$app_cert_sha1"
  receipt_set_string "signing.appLeafCertificatePath" "${app_cert_prefix}0"
  receipt_set_string "signing.widgetLeafCertificatePath" "${widget_cert_prefix}0"
  # DMGも、Xcodeが実際にexportへ使った同じ証明書で署名する。
  SIGN_ID="$app_cert_sha1"

  actual=$(codesign_team_id "$APP")
  [ "$actual" = "$TEAM_ID" ] || { fail "アプリのTeam ID不一致: $actual"; return 1; }
  actual=$(codesign_team_id "$widget")
  [ "$actual" = "$TEAM_ID" ] || { fail "WidgetのTeam ID不一致: $actual"; return 1; }

  actual=$(plist_value CFBundleIdentifier "$app_plist")
  [ "$actual" = "$APP_BUNDLE_ID" ] || { fail "アプリのBundle ID不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$widget_plist")
  [ "$actual" = "$WIDGET_BUNDLE_ID" ] || { fail "WidgetのBundle ID不一致: $actual"; return 1; }

  actual=$(plist_value CFBundleShortVersionString "$app_plist")
  [ "$actual" = "$VERSION" ] || { fail "アプリのversion不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$app_plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "アプリのbuild number不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$widget_plist")
  [ "$actual" = "$VERSION" ] || { fail "Widgetのversion不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$widget_plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "Widgetのbuild number不一致: $actual"; return 1; }

  actual=$(plist_value SUFeedURL "$app_plist")
  [ "$actual" = "$SPARKLE_FEED_URL" ] || { fail "Sparkle feed URL不一致: $actual"; return 1; }
  actual=$(plist_value SUPublicEDKey "$app_plist")
  [ "$actual" = "$SPARKLE_PUBLIC_KEY" ] || { fail "Sparkle公開鍵不一致"; return 1; }
  actual=$(plist_value SUVerifyUpdateBeforeExtraction "$app_plist")
  [ "$actual" = "true" ] || { fail "更新アーカイブの展開前検証が有効ではありません"; return 1; }
  actual=$(plist_value SURequireSignedFeed "$app_plist")
  [ "$actual" = "true" ] || { fail "署名済みappcastが必須になっていません"; return 1; }
  actual=$(plist_value SUScheduledCheckInterval "$app_plist")
  [ "$actual" = "86400" ] || { fail "更新確認間隔が想定外です: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$sparkle_plist")
  [ "$actual" = "$SPARKLE_VERSION" ] || { fail "Sparkle version不一致: $actual"; return 1; }
  otool -L "$APP/Contents/MacOS/$APP_NAME" \
    | /usr/bin/awk 'index($1, "@rpath/Sparkle.framework/") {found=1} END {exit found ? 0 : 1}' \
    || { fail "アプリ実行ファイルが内包Sparkle.frameworkを参照していません"; return 1; }

  receipt_set_string "update.feedURL" "$SPARKLE_FEED_URL"
  receipt_set_string "update.publicEdKey" "$SPARKLE_PUBLIC_KEY"
  receipt_set_string "update.sparkleVersion" "$SPARKLE_VERSION"
  receipt_set_string "update.requiresSignedFeed" "true"
  receipt_set_string "update.verifiesBeforeExtraction" "true"

  codesign -d --entitlements :- "$APP" >"$app_entitlements" 2>"$app_entitlements_stderr"
  codesign -d --entitlements :- "$widget" >"$widget_entitlements" 2>"$widget_entitlements_stderr"
  chmod 600 "$app_entitlements" "$widget_entitlements" \
    "$app_entitlements_stderr" "$widget_entitlements_stderr"
  plutil -lint "$app_entitlements" >/dev/null
  plutil -lint "$widget_entitlements" >/dev/null

  if actual=$(entitlement_value "com.apple.security.app-sandbox" "$app_entitlements"); then
    [ "$actual" = "false" ] || { fail "非sandboxであるべきアプリにapp-sandbox entitlementがあります"; return 1; }
  fi
  actual=$(entitlement_value "com.apple.security.app-sandbox" "$widget_entitlements" || printf '')
  [ "$actual" = "true" ] || { fail "Widgetのapp-sandbox entitlementがありません"; return 1; }

  actual=$(entitlement_value "com.apple.security.application-groups:0" "$app_entitlements" || printf '')
  [ "$actual" = "$expected_app_group" ] || { fail "アプリのApp Group不一致: $actual"; return 1; }
  actual=$(entitlement_value "com.apple.security.application-groups:0" "$widget_entitlements" || printf '')
  [ "$actual" = "$expected_app_group" ] || { fail "WidgetのApp Group不一致: $actual"; return 1; }
  if entitlement_value "com.apple.security.application-groups:1" "$app_entitlements" >/dev/null \
     || entitlement_value "com.apple.security.application-groups:1" "$widget_entitlements" >/dev/null; then
    fail "想定外の追加App Group entitlementがあります"
    return 1
  fi

  if actual=$(entitlement_value "com.apple.security.get-task-allow" "$app_entitlements"); then
    [ "$actual" = "false" ] || { fail "アプリにget-task-allow entitlementがあります"; return 1; }
  fi
  if actual=$(entitlement_value "com.apple.security.get-task-allow" "$widget_entitlements"); then
    [ "$actual" = "false" ] || { fail "Widgetにget-task-allow entitlementがあります"; return 1; }
  fi
  codesign_has_hardened_runtime "$APP" || { fail "アプリにhardened runtimeがありません"; return 1; }
  codesign_has_hardened_runtime "$widget" || { fail "Widgetにhardened runtimeがありません"; return 1; }

  receipt_set_string "artifacts.exportedAppEntitlementsPath" "$app_entitlements"
  receipt_set_string "artifacts.exportedAppEntitlementsSha256" \
    "$(shasum -a 256 "$app_entitlements" | /usr/bin/awk '{print $1}')"
  receipt_set_string "artifacts.exportedWidgetEntitlementsPath" "$widget_entitlements"
  receipt_set_string "artifacts.exportedWidgetEntitlementsSha256" \
    "$(shasum -a 256 "$widget_entitlements" | /usr/bin/awk '{print $1}')"
}

submit_and_record_notarization() {
  local artifact_path=$1
  local label=$2
  local response_path="$RECORD_DIR/$label-submit.json"
  local response_stderr_path="$RECORD_DIR/$label-submit.stderr.log"
  local log_path="$RECORD_DIR/$label-notary-log.json"
  local log_stderr_path="$RECORD_DIR/$label-notary-log.stderr.log"
  local command_status
  local log_command_status=1
  local log_attempt_count=0
  local submission_id=""
  local submission_status="command-failed"
  local log_status="unknown"
  local log_status_code="unknown"
  local issue_count="unknown"
  local artifact_hash
  local log_ok=0

  artifact_hash=$(shasum -a 256 "$artifact_path" | /usr/bin/awk '{print $1}')
  receipt_set_string "notarization.$label.submittedSha256" "$artifact_hash"
  receipt_set_string "notarization.$label.responsePath" "$response_path"
  receipt_set_string "notarization.$label.responseStderrPath" "$response_stderr_path"
  receipt_set_string "notarization.$label.logPath" "$log_path"
  receipt_set_string "notarization.$label.logStderrPath" "$log_stderr_path"
  receipt_set_string "notarization.$label.status" "submitting"

  set +e
  xcrun notarytool submit "$artifact_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 2h --output-format json >"$response_path" 2>"$response_stderr_path"
  command_status=$?
  set -e
  chmod 600 "$response_path" "$response_stderr_path"
  receipt_set_integer "notarization.$label.submitExitStatus" "$command_status"
  receipt_set_string "notarization.$label.responseSha256" \
    "$(shasum -a 256 "$response_path" | /usr/bin/awk '{print $1}')"
  receipt_set_string "notarization.$label.responseStderrSha256" \
    "$(shasum -a 256 "$response_stderr_path" | /usr/bin/awk '{print $1}')"

  if submission_id=$(plutil -extract id raw -expect string "$response_path" 2>/dev/null); then
    submission_status=$(plutil -extract status raw -expect string "$response_path" 2>/dev/null || printf 'unknown')
  fi

  if [ -n "$submission_id" ]; then
    receipt_set_string "notarization.$label.submissionId" "$submission_id"
    : >"$log_stderr_path"
    set +e
    while [ "$log_attempt_count" -lt 3 ]; do
      log_attempt_count=$((log_attempt_count + 1))
      rm -f "$log_path"
      printf 'attempt %s\n' "$log_attempt_count" >>"$log_stderr_path"
      xcrun notarytool log \
        --keychain-profile "$NOTARY_PROFILE" \
        "$submission_id" "$log_path" \
        >/dev/null 2>>"$log_stderr_path"
      log_command_status=$?
      if [ "$log_command_status" -eq 0 ]; then
        break
      fi
      if [ "$log_attempt_count" -lt 3 ]; then
        sleep "$log_attempt_count"
      fi
    done
    set -e
    chmod 600 "$log_stderr_path"
    receipt_set_integer "notarization.$label.logAttemptCount" "$log_attempt_count"
    receipt_set_integer "notarization.$label.logExitStatus" "$log_command_status"
    receipt_set_string "notarization.$label.logStderrSha256" \
      "$(shasum -a 256 "$log_stderr_path" | /usr/bin/awk '{print $1}')"
    if [ "$log_command_status" -eq 0 ] && [ -f "$log_path" ]; then
      chmod 600 "$log_path"
      receipt_set_string "notarization.$label.logSha256" \
        "$(shasum -a 256 "$log_path" | /usr/bin/awk '{print $1}')"
      if issue_count=$(jq -er \
          'if .issues == null then 0
           elif (.issues | type) == "array" then (.issues | length)
           else error("issues must be null or an array") end' "$log_path" 2>/dev/null) \
         && log_status=$(jq -er '.status | select(type == "string")' "$log_path" 2>/dev/null) \
         && log_status_code=$(jq -er '.statusCode | select(type == "number")' "$log_path" 2>/dev/null); then
        receipt_set_integer "notarization.$label.issueCount" "$issue_count"
        receipt_set_string "notarization.$label.logStatus" "$log_status"
        receipt_set_integer "notarization.$label.logStatusCode" "$log_status_code"
        if [ "$log_status" = "$submission_status" ] && [ "$log_status_code" -eq 0 ]; then
          log_ok=1
        fi
      fi
    fi
  fi

  receipt_set_string "notarization.$label.status" "$submission_status"
  printf '    id: %s\n' "${submission_id:-<unavailable>}"
  printf '    status: %s\n' "$submission_status"
  printf '    issues: %s\n' "$issue_count"
  printf '    response: %s\n' "$response_path"
  printf '    log: %s\n' "$log_path"

  if [ "$command_status" -ne 0 ] || [ "$submission_status" != "Accepted" ]; then
    fail "$label の公証がAcceptedになりませんでした。receiptのsubmission IDを確認し、盲目的に再送しないでください。"
    return 1
  fi
  if [ "$log_ok" -ne 1 ]; then
    fail "$label の公証ログを保存・検証できませんでした。submission ID $submission_id を使って取得してください。"
    return 1
  fi
  if [ "$issue_count" != "0" ]; then
    warn "$label の公証ログにissueがあります。配布前に $log_path を確認してください。"
  fi
}

verify_dmg_contents() {
  local verification_label=$1
  local mounted_app
  local mounted_widget
  local mounted_sparkle
  local mounted_notices
  local actual
  local exported_widget="$APP/Contents/PlugIns/AIUsageWidget.appex"
  local exported_sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  local visible_items

  echo "  -- $verification_label: DMG内のlayoutとアプリ --"
  MOUNT_DIR=$(mktemp -d "$WORK_DIR/mount.XXXXXX")
  if diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$MOUNT_DIR" \
       "$DMG" >/dev/null 2>&1; then
    MOUNTED=1
  elif hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" \
         "$DMG" >/dev/null 2>&1; then
    MOUNTED=1
  else
    fail "DMGを読み取り専用でマウントできませんでした"
    return 1
  fi

  mounted_app="$MOUNT_DIR/$APP_NAME.app"
  mounted_widget="$mounted_app/Contents/PlugIns/AIUsageWidget.appex"
  mounted_sparkle="$mounted_app/Contents/Frameworks/Sparkle.framework"
  mounted_notices="$mounted_app/Contents/Resources/Third-Party-Notices.txt"
  [ -d "$mounted_app" ] || { fail "DMG内に $APP_NAME.app がありません"; return 1; }
  [ -d "$mounted_widget" ] || { fail "DMG内にWidget拡張がありません"; return 1; }
  [ -d "$mounted_sparkle" ] || { fail "DMG内アプリにSparkle.frameworkがありません"; return 1; }
  [ -s "$mounted_notices" ] || { fail "DMG内アプリにライセンス・third-party noticesがありません"; return 1; }
  [ -L "$MOUNT_DIR/Applications" ] || { fail "DMG内にApplicationsリンクがありません"; return 1; }
  [ "$(readlink "$MOUNT_DIR/Applications")" = "/Applications" ] \
    || { fail "DMG内のApplicationsリンク先が不正です"; return 1; }
  [ -s "$MOUNT_DIR/.DS_Store" ] || { fail "DMG内にFinderレイアウトがありません"; return 1; }
  [ -s "$MOUNT_DIR/.background.png" ] \
    || { fail "DMG内に案内背景がありません"; return 1; }
  [ "$(shasum -a 256 "$MOUNT_DIR/.background.png" | /usr/bin/awk '{print $1}')" \
     = "$(shasum -a 256 "$DMG_BACKGROUND" | /usr/bin/awk '{print $1}')" ] \
    || { fail "DMG内の案内背景が生成物と一致しません"; return 1; }

  if ! "$DMGBUILD_PYTHON" - "$MOUNT_DIR/.DS_Store" <<'PY'
import sys
from ds_store import DSStore

with DSStore.open(sys.argv[1], "r") as store:
    records = {(entry.filename, entry.code): entry.value for entry in store}

bwsp = records.get((".", b"bwsp"), {})
icvp = records.get((".", b"icvp"), {})
expected_locations = {
    ("AI Usage.app", b"Iloc"): (180, 135),
    ("Applications", b"Iloc"): (620, 135),
}
valid = (
    records.get((".", b"icvl")) == b"icnv"
    and bwsp.get("WindowBounds") == "{{200, 200}, {800, 500}}"
    and not any(bwsp.get(key, True) for key in (
        "ShowPathbar", "ShowSidebar", "ShowStatusBar", "ShowTabView", "ShowToolbar"
    ))
    and icvp.get("arrangeBy") == "none"
    and icvp.get("backgroundType") == 2
    and icvp.get("iconSize") == 96.0
    and icvp.get("textSize") == 14.0
    and all(records.get(key) == value for key, value in expected_locations.items())
)
raise SystemExit(0 if valid else 1)
PY
  then
    fail "DMG内のFinderレイアウトが設定値と一致しません"
    return 1
  fi

  visible_items=("$MOUNT_DIR"/*)
  [ "${#visible_items[@]}" -eq 2 ] \
    || { fail "DMG rootの可視項目が2件ではありません"; return 1; }

  codesign --verify --deep --strict --verbose=2 "$mounted_app" 2>&1 | sed 's/^/    /'
  codesign --verify --strict --verbose=2 "$mounted_widget" 2>&1 | sed 's/^/    /'
  codesign --verify --deep --strict --verbose=2 "$mounted_sparkle" 2>&1 | sed 's/^/    /'
  [ "$(codesign_cdhash "$mounted_app")" = "$(codesign_cdhash "$APP")" ] \
    || { fail "DMG内アプリのCDHashがexportと一致しません"; return 1; }
  [ "$(codesign_cdhash "$mounted_widget")" = "$(codesign_cdhash "$exported_widget")" ] \
    || { fail "DMG内WidgetのCDHashがexportと一致しません"; return 1; }
  [ "$(codesign_cdhash "$mounted_sparkle")" = "$(codesign_cdhash "$exported_sparkle")" ] \
    || { fail "DMG内Sparkle.frameworkのCDHashがexportと一致しません"; return 1; }
  [ "$(shasum -a 256 "$mounted_notices" | /usr/bin/awk '{print $1}')" \
    = "$(shasum -a 256 "$APP/Contents/Resources/Third-Party-Notices.txt" | /usr/bin/awk '{print $1}')" ] \
    || { fail "DMG内のライセンス・third-party noticesがexportと一致しません"; return 1; }

  actual=$(codesign_team_id "$mounted_app")
  [ "$actual" = "$TEAM_ID" ] || { fail "DMG内アプリのTeam ID不一致: $actual"; return 1; }
  actual=$(codesign_team_id "$mounted_widget")
  [ "$actual" = "$TEAM_ID" ] || { fail "DMG内WidgetのTeam ID不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$APP_BUNDLE_ID" ] || { fail "DMG内アプリのBundle ID不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleIdentifier "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$WIDGET_BUNDLE_ID" ] || { fail "DMG内WidgetのBundle ID不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$VERSION" ] || { fail "DMG内アプリのversion不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "DMG内アプリのbuild不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleShortVersionString "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$VERSION" ] || { fail "DMG内Widgetのversion不一致: $actual"; return 1; }
  actual=$(plist_value CFBundleVersion "$mounted_widget/Contents/Info.plist")
  [ "$actual" = "$BUILD_NUMBER" ] || { fail "DMG内Widgetのbuild不一致: $actual"; return 1; }
  actual=$(plist_value SUFeedURL "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$SPARKLE_FEED_URL" ] || { fail "DMG内アプリのSparkle feed URL不一致: $actual"; return 1; }
  actual=$(plist_value SUPublicEDKey "$mounted_app/Contents/Info.plist")
  [ "$actual" = "$SPARKLE_PUBLIC_KEY" ] || { fail "DMG内アプリのSparkle公開鍵不一致"; return 1; }

  if [ "$UNNOTARIZED" -eq 0 ]; then
    spctl --assess --type execute -vv "$mounted_app" 2>&1 | sed 's/^/    /'
    xcrun stapler validate "$mounted_app" 2>&1 | sed 's/^/    /'
  fi

  if ! cleanup_mount; then
    return 1
  fi
  MOUNT_DIR=""
  return 0
}

prepare_receipt_for_publication() {
  local intended_final_state=$1
  local final_dmg_hash
  local receipt_hash_file="$PROVENANCE.sha256"

  final_dmg_hash=$(shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')
  printf '%s  %s\n' "$final_dmg_hash" "$(basename "$FINAL_DMG")" >"$WORK_DMG_HASH_FILE"

  receipt_set_string "artifacts.dmgPath" "$FINAL_DMG"
  receipt_set_string "artifacts.dmgFinalSha256" "$final_dmg_hash"
  receipt_set_string "artifacts.dmgSha256Path" "$FINAL_DMG_HASH_FILE"
  receipt_set_string "release.intendedFinalState" "$intended_final_state"
  receipt_set_string "verifiedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  receipt_set_string "state" "verified-awaiting-publication"
  plutil -convert json -r "$PROVENANCE"
  chmod 600 "$PROVENANCE"
  shasum -a 256 "$PROVENANCE" >"$receipt_hash_file"
  chmod 600 "$receipt_hash_file"
  chmod 644 "$DMG" "$WORK_DMG_HASH_FILE"
}

complete_receipt() {
  local final_state=$1
  local expected_hash
  local actual_hash
  local receipt_hash_file="$PROVENANCE.sha256"

  expected_hash=$(/usr/bin/awk 'NR == 1 {print $1}' "$FINAL_DMG_HASH_FILE")
  actual_hash=$(shasum -a 256 "$FINAL_DMG" | /usr/bin/awk '{print $1}')
  [ -n "$expected_hash" ] && [ "$actual_hash" = "$expected_hash" ] \
    || { fail "公開後のDMGとchecksumが一致しません"; return 1; }

  receipt_set_string "completedAt" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  receipt_set_string "state" "$final_state"
  plutil -convert json -r "$PROVENANCE"
  chmod 600 "$PROVENANCE"
  shasum -a 256 "$PROVENANCE" >"$receipt_hash_file"
  chmod 600 "$receipt_hash_file"
}

publish_artifacts() {
  mkdir -p "$(dirname "$FINAL_DMG")"
  if [ -e "$FINAL_DMG" ] || [ -e "$FINAL_DMG_HASH_FILE" ]; then
    fail "公開直前に同じバージョンの出力を検出しました: $FINAL_DMG"
    return 1
  fi

  # checksumを先にhard-linkし、DMGを最後にlinkする。途中中断で未検証DMG名を残さない。
  if ! ln "$WORK_DMG_HASH_FILE" "$FINAL_DMG_HASH_FILE"; then
    fail "SHA-256成果物を公開先へ配置できませんでした"
    return 1
  fi
  if ! ln "$DMG" "$FINAL_DMG"; then
    rm "$FINAL_DMG_HASH_FILE"
    fail "DMG成果物を公開先へ配置できませんでした"
    return 1
  fi
  ARTIFACTS_PUBLISHED=1

  chmod 644 "$FINAL_DMG" "$FINAL_DMG_HASH_FILE"
  if ! rm "$DMG" "$WORK_DMG_HASH_FILE"; then
    warn "検証済みworking artifactを削除できませんでした: $WORK_DIR"
  fi
  DMG="$FINAL_DMG"
  DMG_HASH_FILE="$FINAL_DMG_HASH_FILE"
}

# ---------- ビルド ----------
CURRENT_STEP="xcodegen"
echo "==> プロジェクトを生成"
run_logged "$RECORD_DIR/xcodegen.log" xcodegen generate

CURRENT_STEP="source-provenance"
check_git_source_checkpoint "xcodegen後"
SOURCE_SHA256=$(write_source_manifest "$SOURCE_MANIFEST")
receipt_set_string "source.manifestPath" "$SOURCE_MANIFEST"
receipt_set_string "source.manifestSha256" "$SOURCE_SHA256"

CURRENT_STEP="archive"
echo "==> アーカイブ ($VERSION / $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
run_logged "$RECORD_DIR/xcodebuild-archive.log" \
  xcodebuild archive \
    -project "$PROJECT_NAME.xcodeproj" \
    -scheme "$PROJECT_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
    -onlyUsePackageVersionsFromResolvedFile \
    -packageAuthorizationProvider netrc \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID"

[ -d "$ARCHIVE" ] || { fail "アーカイブが生成されませんでした"; exit 1; }

CURRENT_STEP="archive-recording"
echo "==> dSYMとxcarchive metadataをrelease記録へ保存"
HOST_DSYM="$ARCHIVE/dSYMs/$APP_NAME.app.dSYM"
WIDGET_DSYM="$ARCHIVE/dSYMs/AIUsageWidget.appex.dSYM"
XCARCHIVE_INFO="$ARCHIVE/Info.plist"
RECORDED_HOST_DSYM="$DEBUG_SYMBOL_DIR/$(basename "$HOST_DSYM")"
RECORDED_WIDGET_DSYM="$DEBUG_SYMBOL_DIR/$(basename "$WIDGET_DSYM")"
HOST_DSYM_MANIFEST="$RECORD_DIR/host-dsym-sha256.txt"
WIDGET_DSYM_MANIFEST="$RECORD_DIR/widget-dsym-sha256.txt"
RECORDED_XCARCHIVE_INFO="$RECORD_DIR/xcarchive-Info.plist"

[ -d "$HOST_DSYM" ] || { fail "アプリのdSYMがarchiveにありません: $HOST_DSYM"; exit 1; }
[ -d "$WIDGET_DSYM" ] || { fail "WidgetのdSYMがarchiveにありません: $WIDGET_DSYM"; exit 1; }
[ -f "$XCARCHIVE_INFO" ] || { fail "xcarchiveのInfo.plistがありません: $XCARCHIVE_INFO"; exit 1; }

mkdir "$DEBUG_SYMBOL_DIR"
ditto "$HOST_DSYM" "$RECORDED_HOST_DSYM"
ditto "$WIDGET_DSYM" "$RECORDED_WIDGET_DSYM"
cp "$XCARCHIVE_INFO" "$RECORDED_XCARCHIVE_INFO"
chmod -R go-rwx "$DEBUG_SYMBOL_DIR"
chmod 600 "$RECORDED_XCARCHIVE_INFO"

HOST_DSYM_MANIFEST_SHA256=$(write_tree_manifest "$RECORDED_HOST_DSYM" "$HOST_DSYM_MANIFEST")
WIDGET_DSYM_MANIFEST_SHA256=$(write_tree_manifest "$RECORDED_WIDGET_DSYM" "$WIDGET_DSYM_MANIFEST")
XCARCHIVE_INFO_SHA256=$(shasum -a 256 "$RECORDED_XCARCHIVE_INFO" | /usr/bin/awk '{print $1}')
receipt_set_string "artifacts.hostDsymPath" "$RECORDED_HOST_DSYM"
receipt_set_string "artifacts.hostDsymManifestPath" "$HOST_DSYM_MANIFEST"
receipt_set_string "artifacts.hostDsymManifestSha256" "$HOST_DSYM_MANIFEST_SHA256"
receipt_set_string "artifacts.widgetDsymPath" "$RECORDED_WIDGET_DSYM"
receipt_set_string "artifacts.widgetDsymManifestPath" "$WIDGET_DSYM_MANIFEST"
receipt_set_string "artifacts.widgetDsymManifestSha256" "$WIDGET_DSYM_MANIFEST_SHA256"
receipt_set_string "artifacts.xcarchiveInfoPath" "$RECORDED_XCARCHIVE_INFO"
receipt_set_string "artifacts.xcarchiveInfoSha256" "$XCARCHIVE_INFO_SHA256"

CURRENT_STEP="export"
echo "==> Developer ID で書き出し"
run_logged "$RECORD_DIR/xcodebuild-export.log" \
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist packaging/ExportOptions.plist \
    -exportPath "$EXPORT_DIR"

APP="$EXPORT_DIR/$APP_NAME.app"
CURRENT_STEP="export-verification"
echo "==> 署名・bundle identity・versionを確認"
verify_exported_app

SOURCE_SHA256_AFTER=$(write_source_manifest "$SOURCE_MANIFEST_AFTER")
receipt_set_string "source.manifestAfterBuildPath" "$SOURCE_MANIFEST_AFTER"
receipt_set_string "source.manifestAfterBuildSha256" "$SOURCE_SHA256_AFTER"
check_git_source_checkpoint "archive/export後"
if [ "$SOURCE_SHA256_AFTER" != "$SOURCE_SHA256" ]; then
  fail "ビルド中にソースが変化しました。成果物を公証しません。"
  exit 1
fi

CURRENT_STEP="dmg-input-snapshot"
echo "==> DMG入力をbuild sourceから固定"
snapshot_dmg_inputs

# ---------- アプリ単体の公証 ----------
# DMG から取り出したあと初回起動がオフラインでも通るよう、.app にもチケットを貼る。
if [ "$UNNOTARIZED" -eq 0 ]; then
  CURRENT_STEP="app-notarization"
  echo "==> アプリを公証（1/2）"
  APP_ZIP="$RECORD_DIR/$PROJECT_NAME-notary.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  chmod 600 "$APP_ZIP"
  receipt_set_string "artifacts.appNotaryZipPath" "$APP_ZIP"
  submit_and_record_notarization "$APP_ZIP" "app"
  xcrun stapler staple "$APP" | sed 's/^/    /'
  xcrun stapler validate "$APP" 2>&1 | sed 's/^/    /'
fi

# ---------- DMG ----------
CURRENT_STEP="dmg-source-verification"
check_git_source_checkpoint "DMG生成前"
SOURCE_SHA256_BEFORE_DMG=$(write_source_manifest "$SOURCE_MANIFEST_BEFORE_DMG")
receipt_set_string "source.manifestBeforeDmgPath" "$SOURCE_MANIFEST_BEFORE_DMG"
receipt_set_string "source.manifestBeforeDmgSha256" "$SOURCE_SHA256_BEFORE_DMG"
if [ "$SOURCE_SHA256_BEFORE_DMG" != "$SOURCE_SHA256_AFTER" ]; then
  fail "アプリ公証待ちの間にソースが変化しました。DMGを生成しません。"
  exit 1
fi
if ! inspect_release_tools; then
  fail "DMG生成直前にrelease toolを検証できません: $RELEASE_TOOLS_ERROR"
  exit 1
fi
if [ "$(shasum -a 256 "$DMGBUILD_STAMP" | /usr/bin/awk '{print $1}')" \
     != "$(shasum -a 256 "$DMGBUILD_STAMP_SNAPSHOT" | /usr/bin/awk '{print $1}')" ]; then
  fail "release tool stampがbuild中に変化しました"
  exit 1
fi

CURRENT_STEP="dmg-creation"
echo "==> DMG を作成"
mkdir -p "$(dirname "$DMG")"
DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" xcrun swift \
  "$DMG_BACKGROUND_RENDERER_SNAPSHOT" "$DMG_BACKGROUND"

BACKGROUND_WIDTH=$(sips -g pixelWidth "$DMG_BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ {print $2}')
BACKGROUND_HEIGHT=$(sips -g pixelHeight "$DMG_BACKGROUND" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ {print $2}')
if [ "$BACKGROUND_WIDTH" != "800" ] || [ "$BACKGROUND_HEIGHT" != "500" ]; then
  fail "DMG背景の寸法が不正です: ${BACKGROUND_WIDTH:-?}x${BACKGROUND_HEIGHT:-?}"
  exit 1
fi

receipt_set_string "artifacts.dmgLayout.generator" "dmgbuild"
receipt_set_string "artifacts.dmgLayout.generatorVersion" "$ACTUAL_DMGBUILD_VERSION"
receipt_set_string "artifacts.dmgLayout.dsStoreVersion" "$ACTUAL_DS_STORE_VERSION"
receipt_set_string "artifacts.dmgLayout.macAliasVersion" "$ACTUAL_MAC_ALIAS_VERSION"
receipt_set_string "artifacts.dmgLayout.pythonVersion" "$ACTUAL_RELEASE_PYTHON_VERSION"
receipt_set_string "artifacts.dmgLayout.requirementsSha256" \
  "$(shasum -a 256 "$DMG_REQUIREMENTS_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.settingsSha256" \
  "$(shasum -a 256 "$DMG_SETTINGS_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.rendererSha256" \
  "$(shasum -a 256 "$DMG_BACKGROUND_RENDERER_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.toolchainStampSha256" \
  "$(shasum -a 256 "$DMGBUILD_STAMP_SNAPSHOT" | /usr/bin/awk '{print $1}')"
receipt_set_string "artifacts.dmgLayout.backgroundSha256" \
  "$(shasum -a 256 "$DMG_BACKGROUND" | /usr/bin/awk '{print $1}')"

"$DMGBUILD_PYTHON" -m dmgbuild \
  --no-hidpi \
  -s "$DMG_SETTINGS_SNAPSHOT" \
  -D "app=$APP" \
  -D "background=$DMG_BACKGROUND" \
  "$VOLUME_NAME" "$DMG"
echo "    created (dmgbuild $ACTUAL_DMGBUILD_VERSION)"

CURRENT_STEP="dmg-source-postcheck"
if ! inspect_release_tools; then
  fail "DMG生成後にrelease toolを検証できません: $RELEASE_TOOLS_ERROR"
  exit 1
fi
check_git_source_checkpoint "DMG生成後"
SOURCE_SHA256_AFTER_DMG=$(write_source_manifest "$SOURCE_MANIFEST_AFTER_DMG")
receipt_set_string "source.manifestAfterDmgPath" "$SOURCE_MANIFEST_AFTER_DMG"
receipt_set_string "source.manifestAfterDmgSha256" "$SOURCE_SHA256_AFTER_DMG"
if [ "$SOURCE_SHA256_AFTER_DMG" != "$SOURCE_SHA256_AFTER" ]; then
  fail "DMG生成中にソースが変化しました。成果物を署名しません。"
  exit 1
fi

CURRENT_STEP="dmg-signing"
echo "==> DMG にTeam ${TEAM_ID}の証明書で署名"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=4 "$DMG" 2>&1 | sed 's/^/    /'
DMG_TEAM_ID=$(codesign_team_id "$DMG")
if [ "$DMG_TEAM_ID" != "$TEAM_ID" ]; then
  fail "DMGのTeam ID不一致: $DMG_TEAM_ID"
  exit 1
fi

CURRENT_STEP="dmg-content-verification"
verify_dmg_contents "公証前検証"
receipt_set_string "artifacts.dmgLayout.preNotarizationVerification" "passed"

if [ "$UNNOTARIZED" -eq 1 ]; then
  CURRENT_STEP="receipt-preparation"
  prepare_receipt_for_publication "complete-unnotarized"
  CURRENT_STEP="artifact-promotion"
  publish_artifacts
  CURRENT_STEP="receipt-completion"
  complete_receipt "complete-unnotarized"
  CURRENT_STEP="complete"
  warn "公証なし成果物です。Gatekeeperで拒否されるため正規配布には使用しないでください。"
  green "検証用DMG: $DMG"
  green "SHA-256: $DMG_HASH_FILE"
  green "release記録: $PROVENANCE"
  exit 0
fi

# ---------- DMG 公証 ----------
CURRENT_STEP="dmg-notarization"
echo "==> DMG を公証（2/2）"
submit_and_record_notarization "$DMG" "dmg"

CURRENT_STEP="dmg-stapling"
echo "==> ステープル"
xcrun stapler staple "$DMG" | sed 's/^/    /'

# ---------- 最終確認 ----------
CURRENT_STEP="final-verification"
echo "==> 最終確認"
echo "  -- DMG --"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$DMG" 2>&1 | sed 's/^/    /'
verify_dmg_contents "最終成果物"
receipt_set_string "artifacts.dmgLayout.finalVerification" "passed"

CURRENT_STEP="receipt-preparation"
prepare_receipt_for_publication "complete"
CURRENT_STEP="artifact-promotion"
publish_artifacts
CURRENT_STEP="receipt-completion"
complete_receipt "complete"
CURRENT_STEP="complete"

green "できました: $DMG"
green "SHA-256: $DMG_HASH_FILE"
green "release記録: $PROVENANCE"
