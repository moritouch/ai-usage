#!/bin/bash
# 公開済みimmutable GitHub Releaseを検証し、Cloudflare配信用assetとSparkle appcastを準備する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.9.6"
SPARKLE_TOOLS="$ROOT/build/sparkle-tools/$SPARKLE_VERSION/bin"
KEYCHAIN_ACCOUNT="jp.co.forestx.aiusage"
APP_BUNDLE_ID="jp.co.forestx.aiusage"
APP_NAME="AI Usage"
PRODUCT_URL="https://moritouch.com/ai-usage"
FEED_URL="$PRODUCT_URL/appcast.xml"
PUBLIC_DOWNLOAD_BASE="$PRODUCT_URL/releases"
CLOUDFLARE_MAX_STATIC_ASSET_BYTES=$((25 * 1024 * 1024))

REPOSITORY=""
TAG=""
OUTPUT=""
PUBLIC_ASSETS_ROOT=""
WORK_DIR=""
MOUNT_DIR=""
MOUNTED=0
LOCK_DIR="$ROOT/build/appcast.lock"
LOCK_HELD=0
ASSET_STAGE_DIR=""
ASSET_LOCK_DIR=""
ASSET_LOCK_HELD=0
ASSET_STAGE_RESULT=""

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/prepare-appcast.sh \
    --repository OWNER/REPO \
    --tag vX.Y.Z \
    --public-assets-root /path/to/profile/public/ai-usage/releases \
    --output /path/to/appcast.xml

The GitHub Release must already be published, non-prerelease, immutable,
and attested. Its notarized AIUsage-X.Y.Z.dmg and matching .sha256 must be
identical to the two files in local dist/. The two files are staged atomically at
PUBLIC_ASSETS_ROOT/vX.Y.Z/ and the signed appcast points to:

  https://moritouch.com/ai-usage/releases/vX.Y.Z/AIUsage-X.Y.Z.dmg

PUBLIC_ASSETS_ROOT must be an absolute, existing, non-symlink directory whose
path ends in /public/ai-usage/releases. Existing version directories are accepted
only when they contain exactly the same two regular files byte-for-byte. Existing
appcast history is preserved and delta updates remain disabled.

Sparkle's private EdDSA key is read only from the macOS Keychain account
jp.co.forestx.aiusage. The private key is never exported or printed.
USAGE
}

cleanup_mount() {
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    if diskutil image detach "$MOUNT_DIR" >/dev/null 2>&1 \
       || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1; then
      MOUNTED=0
    else
      return 1
    fi
  fi
}

cleanup() {
  local script_status=$?
  trap - EXIT

  if ! cleanup_mount; then
    printf 'error: DMG mountを解除できませんでした: %s\n' "$MOUNT_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi

  if [ -n "$WORK_DIR" ]; then
    case "$WORK_DIR" in
      "$ROOT"/build/appcast-work.*)
        rm -rf -- "$WORK_DIR"
        ;;
      *)
        printf 'error: unexpected temporary path; not removing: %s\n' "$WORK_DIR" >&2
        if [ "$script_status" -eq 0 ]; then
          script_status=1
        fi
        ;;
    esac
  fi

  if [ -n "$ASSET_STAGE_DIR" ]; then
    case "$ASSET_STAGE_DIR" in
      "$PUBLIC_ASSETS_ROOT"/.v*.stage.*)
        rm -rf -- "$ASSET_STAGE_DIR"
        ;;
      *)
        printf 'error: unexpected asset staging path; not removing: %s\n' \
          "$ASSET_STAGE_DIR" >&2
        if [ "$script_status" -eq 0 ]; then
          script_status=1
        fi
        ;;
    esac
  fi

  if [ "$ASSET_LOCK_HELD" -eq 1 ] && ! rmdir "$ASSET_LOCK_DIR"; then
    printf 'error: public asset lockを解除できませんでした: %s\n' "$ASSET_LOCK_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi

  if [ "$LOCK_HELD" -eq 1 ] && ! rmdir "$LOCK_DIR"; then
    printf 'error: appcast lockを解除できませんでした: %s\n' "$LOCK_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi
  exit "$script_status"
}

canonicalize_public_assets_root() {
  local input=$1
  local canonical

  [[ "$input" == /* ]] \
    || fail "--public-assets-rootは絶対pathで指定してください"
  case "$input" in
    *//*|*/./*|*/../*|*/.|*/..)
      fail "--public-assets-rootに非canonicalなpath要素を使用できません: $input"
      ;;
  esac
  case "$input" in
    */public/ai-usage/releases) ;;
    *)
      fail "--public-assets-rootは/public/ai-usage/releasesで終わる必要があります"
      ;;
  esac
  [ -d "$input" ] && [ ! -L "$input" ] \
    || fail "--public-assets-rootは既存の非symlink directoryを指定してください: $input"

  canonical=$(cd "$input" && pwd -P) \
    || fail "--public-assets-rootを解決できません: $input"
  [ "$canonical" = "$input" ] \
    || fail "--public-assets-rootまたは親directoryにsymlinkを使用できません: $input"
  printf '%s\n' "$canonical"
}

assert_cloudflare_asset_size() {
  local path=$1
  local size

  [ -f "$path" ] && [ ! -L "$path" ] \
    || fail "Cloudflareへ配置するassetが通常fileではありません: $path"
  size=$(stat -f '%z' "$path") \
    || fail "asset sizeを取得できません: $path"
  [ "$size" -lt "$CLOUDFLARE_MAX_STATIC_ASSET_BYTES" ] \
    || fail "Cloudflare Static Assetsの25 MiB未満制約を超えています: $path ($size bytes)"
}

stage_public_release_assets() {
  local target_dir="$PUBLIC_ASSETS_ROOT/$TAG"
  local entry_count

  ASSET_LOCK_DIR="$PUBLIC_ASSETS_ROOT/.$TAG.lock"
  [ ! -e "$ASSET_LOCK_DIR" ] && [ ! -L "$ASSET_LOCK_DIR" ] \
    || fail "public asset lockが既に存在します: $ASSET_LOCK_DIR"
  mkdir "$ASSET_LOCK_DIR" 2>/dev/null \
    || fail "public asset lockを取得できません: $ASSET_LOCK_DIR"
  ASSET_LOCK_HELD=1

  if [ -e "$target_dir" ] || [ -L "$target_dir" ]; then
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] \
      || fail "既存のversion配布先が非symlink directoryではありません: $target_dir"
    [ -f "$target_dir/$DMG_NAME" ] && [ ! -L "$target_dir/$DMG_NAME" ] \
      || fail "既存の公開DMGが通常fileではありません: $target_dir/$DMG_NAME"
    [ -f "$target_dir/$CHECKSUM_NAME" ] && [ ! -L "$target_dir/$CHECKSUM_NAME" ] \
      || fail "既存の公開checksumが通常fileではありません: $target_dir/$CHECKSUM_NAME"
    entry_count=$(find "$target_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')
    [ "$entry_count" = "2" ] \
      || fail "既存のversion配布先はDMG/checksumの2 fileだけである必要があります: $target_dir"
    cmp -s "$RELEASE_DMG" "$target_dir/$DMG_NAME" \
      || fail "既存の公開DMGは検証済みRelease assetとbyte一致しません"
    cmp -s "$RELEASE_CHECKSUM" "$target_dir/$CHECKSUM_NAME" \
      || fail "既存の公開checksumは検証済みRelease assetとbyte一致しません"
    ASSET_STAGE_RESULT="unchanged"
  else
    ASSET_STAGE_DIR=$(mktemp -d "$PUBLIC_ASSETS_ROOT/.$TAG.stage.XXXXXX") \
      || fail "public asset staging directoryを作成できません"
    chmod 755 "$ASSET_STAGE_DIR"
    cp -p "$RELEASE_DMG" "$ASSET_STAGE_DIR/$DMG_NAME"
    cp -p "$RELEASE_CHECKSUM" "$ASSET_STAGE_DIR/$CHECKSUM_NAME"
    chmod 644 "$ASSET_STAGE_DIR/$DMG_NAME" "$ASSET_STAGE_DIR/$CHECKSUM_NAME"
    cmp -s "$RELEASE_DMG" "$ASSET_STAGE_DIR/$DMG_NAME" \
      || fail "stagingしたDMGが検証済みRelease assetと一致しません"
    cmp -s "$RELEASE_CHECKSUM" "$ASSET_STAGE_DIR/$CHECKSUM_NAME" \
      || fail "stagingしたchecksumが検証済みRelease assetと一致しません"
    [ ! -e "$target_dir" ] && [ ! -L "$target_dir" ] \
      || fail "staging中にversion配布先が作成されました: $target_dir"
    mv "$ASSET_STAGE_DIR" "$target_dir"
    ASSET_STAGE_DIR=""
    ASSET_STAGE_RESULT="created"
  fi

  rmdir "$ASSET_LOCK_DIR" \
    || fail "public asset lockを解除できませんでした: $ASSET_LOCK_DIR"
  ASSET_LOCK_HELD=0
}

main() {
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository)
      [ -z "$REPOSITORY" ] || { usage >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REPOSITORY=$2
      shift 2
      ;;
    --tag)
      [ -z "$TAG" ] || { usage >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      TAG=$2
      shift 2
      ;;
    --output)
      [ -z "$OUTPUT" ] || { usage >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OUTPUT=$2
      shift 2
      ;;
    --public-assets-root)
      [ -z "$PUBLIC_ASSETS_ROOT" ] || { usage >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PUBLIC_ASSETS_ROOT=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$REPOSITORY" ] && [ -n "$TAG" ] && [ -n "$PUBLIC_ASSETS_ROOT" ] \
  && [ -n "$OUTPUT" ] \
  || { usage >&2; exit 2; }

[[ "$REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "--repositoryはOWNER/REPO形式で指定してください"
[[ "$TAG" =~ ^v[0-9]+([.][0-9]+)*$ ]] \
  || fail "--tagはvX.Y.Z形式のstable versionを指定してください"
[[ "$OUTPUT" == *.xml ]] || fail "--outputには.xml fileを指定してください"

VERSION=${TAG#v}
DMG_NAME="AIUsage-$VERSION.dmg"
CHECKSUM_NAME="$DMG_NAME.sha256"
LOCAL_DMG="$ROOT/dist/$DMG_NAME"
LOCAL_CHECKSUM="$ROOT/dist/$CHECKSUM_NAME"

OUTPUT_PARENT_INPUT=$(dirname "$OUTPUT")
[ -d "$OUTPUT_PARENT_INPUT" ] \
  || fail "--outputの親directoryがありません: $OUTPUT_PARENT_INPUT"
OUTPUT_PARENT=$(cd "$OUTPUT_PARENT_INPUT" && pwd -P)
OUTPUT_NAME=$(basename "$OUTPUT")
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
[ ! -L "$OUTPUT" ] || fail "symlinkをappcast出力先には使用できません: $OUTPUT"
if [ -e "$OUTPUT" ] && [ ! -f "$OUTPUT" ]; then
  fail "既存のappcast出力先が通常fileではありません: $OUTPUT"
fi

for command_name in gh jq shasum cmp codesign spctl xcrun plutil xmllint python3 \
                    diskutil hdiutil; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "必要なcommandがありません: $command_name"
done

PUBLIC_ASSETS_ROOT=$(canonicalize_public_assets_root "$PUBLIC_ASSETS_ROOT")

[ -f "$LOCAL_DMG" ] && [ ! -L "$LOCAL_DMG" ] \
  || fail "local notarized DMGがありません: $LOCAL_DMG"
[ -f "$LOCAL_CHECKSUM" ] && [ ! -L "$LOCAL_CHECKSUM" ] \
  || fail "local checksumがありません: $LOCAL_CHECKSUM"
[ -f "$ROOT/App/Info.plist" ] || fail "App/Info.plistがありません"

mkdir -p "$ROOT/build"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  fail "別のappcast生成が実行中です: $LOCK_DIR"
fi
LOCK_HELD=1
WORK_DIR=$(mktemp -d "$ROOT/build/appcast-work.XXXXXX")
chmod 700 "$WORK_DIR"

"$ROOT/scripts/bootstrap-sparkle-tools.sh"
GENERATE_APPCAST="$SPARKLE_TOOLS/generate_appcast"
SIGN_UPDATE="$SPARKLE_TOOLS/sign_update"
GENERATE_KEYS="$SPARKLE_TOOLS/generate_keys"

# -pは既存の公開鍵だけを返す。秘密鍵はKeychainからexportせず、出力もしない。
if ! KEYCHAIN_PUBLIC_KEY=$("$GENERATE_KEYS" --account "$KEYCHAIN_ACCOUNT" -p); then
  fail "Sparkle署名鍵をKeychain account $KEYCHAIN_ACCOUNT から取得できません"
fi
APP_PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/App/Info.plist" 2>/dev/null) \
  || fail "App/Info.plistにSUPublicEDKeyがありません"
[ -n "$KEYCHAIN_PUBLIC_KEY" ] && [ "$KEYCHAIN_PUBLIC_KEY" = "$APP_PUBLIC_KEY" ] \
  || fail "KeychainのSparkle公開鍵がApp/Info.plistと一致しません"

if [ -f "$OUTPUT" ]; then
  xmllint --noout "$OUTPUT" || fail "既存appcastがwell-formed XMLではありません"
  "$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$OUTPUT" >/dev/null \
    || fail "既存appcastの署名を検証できません"
fi

REPOSITORY_JSON="$WORK_DIR/repository.json"
if ! gh repo view "$REPOSITORY" --json nameWithOwner,visibility >"$REPOSITORY_JSON"; then
  fail "GitHub repositoryを取得できません: $REPOSITORY"
fi
chmod 600 "$REPOSITORY_JSON"
CANONICAL_REPOSITORY=$(jq -er '.nameWithOwner' "$REPOSITORY_JSON") \
  || fail "GitHubが返したrepository名を取得できません"
[[ "$CANONICAL_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "GitHubが返したrepository名が不正です"
REPOSITORY_VISIBILITY=$(jq -er '.visibility' "$REPOSITORY_JSON") \
  || fail "GitHub repositoryのvisibilityを取得できません"
[ "$REPOSITORY_VISIBILITY" = "PUBLIC" ] \
  || fail "GitHub repositoryはPublicである必要があります: $CANONICAL_REPOSITORY"
REPOSITORY="$CANONICAL_REPOSITORY"

RELEASE_JSON="$WORK_DIR/release.json"
if ! gh release view "$TAG" \
     --repo "$REPOSITORY" \
     --json tagName,isDraft,isPrerelease,isImmutable,publishedAt,assets \
     >"$RELEASE_JSON"; then
  fail "GitHub Releaseを取得できません: $REPOSITORY $TAG"
fi
chmod 600 "$RELEASE_JSON"

jq -e \
  --arg tag "$TAG" \
  --arg dmg "$DMG_NAME" \
  --arg checksum "$CHECKSUM_NAME" '
    .tagName == $tag
    and .isDraft == false
    and .isPrerelease == false
    and .isImmutable == true
    and (.publishedAt | type == "string" and length > 0)
    and (.assets | length == 2)
    and ([.assets[].name] | sort == ([$dmg, $checksum] | sort))
    and (all(.assets[];
          .state == "uploaded"
          and (.size | type == "number" and . > 0)
          and (.digest | type == "string"
               and test("^sha256:[0-9a-f]{64}$"))))
  ' "$RELEASE_JSON" >/dev/null \
  || fail "ReleaseはPublish済み・stable・immutableで、DMG/checksumの2 assetだけである必要があります"

# immutable releaseのGitHub attestationも、appcastへ採用する前に確認する。
gh release verify "$TAG" --repo "$REPOSITORY" >/dev/null \
  || fail "GitHub immutable release attestationを検証できません"

DOWNLOAD_DIR="$WORK_DIR/download"
mkdir "$DOWNLOAD_DIR"
gh release download "$TAG" \
  --repo "$REPOSITORY" \
  --dir "$DOWNLOAD_DIR" \
  --pattern "$DMG_NAME" \
  --pattern "$CHECKSUM_NAME"

PUBLIC_DMG="$DOWNLOAD_DIR/$DMG_NAME"
PUBLIC_CHECKSUM="$DOWNLOAD_DIR/$CHECKSUM_NAME"
[ -f "$PUBLIC_DMG" ] && [ -f "$PUBLIC_CHECKSUM" ] \
  || fail "GitHub ReleaseのDMG/checksumをdownloadできませんでした"
[ "$(find "$DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" = "2" ] \
  || fail "downloadしたasset数が2件ではありません"
RELEASE_DMG="$PUBLIC_DMG"
RELEASE_CHECKSUM="$PUBLIC_CHECKSUM"

file_sha256() {
  shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

checksum_value() {
  local checksum_file=$1
  local expected_name=$2
  /usr/bin/awk -v expected_name="$expected_name" '
    NR == 1 {
      filename=$2
      sub(/^\*/, "", filename)
      if (NF == 2 && length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/ \
          && filename == expected_name) {
        value=tolower($1)
        valid=1
      }
    }
    END {
      if (NR != 1 || !valid) exit 1
      print value
    }
  ' "$checksum_file"
}

PUBLIC_DMG_SHA=$(file_sha256 "$PUBLIC_DMG")
LOCAL_DMG_SHA=$(file_sha256 "$LOCAL_DMG")
PUBLIC_CHECKSUM_VALUE=$(checksum_value "$PUBLIC_CHECKSUM" "$DMG_NAME") \
  || fail "Release checksum fileの形式またはfilenameが不正です"
LOCAL_CHECKSUM_VALUE=$(checksum_value "$LOCAL_CHECKSUM" "$DMG_NAME") \
  || fail "local checksum fileの形式またはfilenameが不正です"
GITHUB_DMG_SHA=$(jq -er --arg name "$DMG_NAME" \
  '.assets[] | select(.name == $name) | .digest | sub("^sha256:"; "")' \
  "$RELEASE_JSON")
GITHUB_CHECKSUM_SHA=$(jq -er --arg name "$CHECKSUM_NAME" \
  '.assets[] | select(.name == $name) | .digest | sub("^sha256:"; "")' \
  "$RELEASE_JSON")
PUBLIC_CHECKSUM_SHA=$(file_sha256 "$PUBLIC_CHECKSUM")

[ "$PUBLIC_DMG_SHA" = "$PUBLIC_CHECKSUM_VALUE" ] \
  || fail "Release DMGとRelease checksumが一致しません"
[ "$PUBLIC_DMG_SHA" = "$GITHUB_DMG_SHA" ] \
  || fail "Release DMGとGitHub asset digestが一致しません"
[ "$PUBLIC_DMG_SHA" = "$LOCAL_DMG_SHA" ] \
  || fail "Release DMGとlocal dist DMGが一致しません"
[ "$LOCAL_DMG_SHA" = "$LOCAL_CHECKSUM_VALUE" ] \
  || fail "local dist DMGとlocal checksumが一致しません"
[ "$PUBLIC_CHECKSUM_SHA" = "$GITHUB_CHECKSUM_SHA" ] \
  || fail "Release checksumとGitHub asset digestが一致しません"
cmp -s "$PUBLIC_CHECKSUM" "$LOCAL_CHECKSUM" \
  || fail "Release checksum fileとlocal checksum fileがbyte単位で一致しません"

GITHUB_DMG_SIZE=$(jq -er --arg name "$DMG_NAME" \
  '.assets[] | select(.name == $name) | .size' "$RELEASE_JSON")
PUBLIC_DMG_SIZE=$(stat -f '%z' "$PUBLIC_DMG")
[ "$PUBLIC_DMG_SIZE" = "$GITHUB_DMG_SIZE" ] \
  || fail "Release DMGのsizeがGitHub metadataと一致しません"

EXPECTED_GITHUB_DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$DMG_NAME"
GITHUB_DOWNLOAD_URL=$(jq -er --arg name "$DMG_NAME" \
  '.assets[] | select(.name == $name) | .url' "$RELEASE_JSON")
[ "$GITHUB_DOWNLOAD_URL" = "$EXPECTED_GITHUB_DOWNLOAD_URL" ] \
  || fail "GitHub Release asset URLが固定tag URLと一致しません"
EXPECTED_DOWNLOAD_URL="$PUBLIC_DOWNLOAD_BASE/$TAG/$DMG_NAME"

assert_cloudflare_asset_size "$RELEASE_DMG"
assert_cloudflare_asset_size "$RELEASE_CHECKSUM"

codesign --verify --deep --strict --verbose=2 "$PUBLIC_DMG" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$PUBLIC_DMG" 2>&1 | sed 's/^/    /'
spctl --assess --type open --context context:primary-signature -vv "$PUBLIC_DMG" 2>&1 \
  | sed 's/^/    /'

MOUNT_DIR="$WORK_DIR/mount"
mkdir "$MOUNT_DIR"
if diskutil image attach \
     --mountOptions nobrowse \
     --readOnly \
     --mountPoint "$MOUNT_DIR" \
     "$PUBLIC_DMG" >/dev/null 2>&1; then
  MOUNTED=1
elif hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" \
       "$PUBLIC_DMG" >/dev/null 2>&1; then
  MOUNTED=1
else
  fail "Release DMGを読み取り専用でmountできません"
fi

MOUNTED_APP="$MOUNT_DIR/$APP_NAME.app"
[ -d "$MOUNTED_APP" ] || fail "Release DMGに$APP_NAME.appがありません"
[ "$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')" = "1" ] \
  || fail "Release DMG内のapp bundleが1件ではありません"

codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$MOUNTED_APP" 2>&1 | sed 's/^/    /'
spctl --assess --type execute -vv "$MOUNTED_APP" 2>&1 | sed 's/^/    /'

APP_INFO="$MOUNTED_APP/Contents/Info.plist"
[ -f "$APP_INFO" ] || fail "Release appのInfo.plistがありません"
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null
}

RELEASE_BUNDLE_ID=$(plist_value CFBundleIdentifier "$APP_INFO")
RELEASE_VERSION=$(plist_value CFBundleShortVersionString "$APP_INFO")
RELEASE_BUILD=$(plist_value CFBundleVersion "$APP_INFO")
RELEASE_FEED_URL=$(plist_value SUFeedURL "$APP_INFO")
RELEASE_PUBLIC_KEY=$(plist_value SUPublicEDKey "$APP_INFO")
REQUIRE_SIGNED_FEED=$(plist_value SURequireSignedFeed "$APP_INFO")
VERIFY_BEFORE_EXTRACTION=$(plist_value SUVerifyUpdateBeforeExtraction "$APP_INFO")

[ "$RELEASE_BUNDLE_ID" = "$APP_BUNDLE_ID" ] \
  || fail "Release appのbundle IDが不正です: $RELEASE_BUNDLE_ID"
[ "$RELEASE_VERSION" = "$VERSION" ] \
  || fail "tagとRelease appのversionが一致しません: $RELEASE_VERSION"
[[ "$RELEASE_BUILD" =~ ^[0-9]+$ ]] \
  || fail "Release appのbuild numberが数値ではありません: $RELEASE_BUILD"
[ "$RELEASE_FEED_URL" = "$FEED_URL" ] \
  || fail "Release appのSparkle feed URLが不正です: $RELEASE_FEED_URL"
[ "$RELEASE_PUBLIC_KEY" = "$KEYCHAIN_PUBLIC_KEY" ] \
  || fail "Release appのSparkle公開鍵がKeychainと一致しません"
[ "$REQUIRE_SIGNED_FEED" = "true" ] \
  || fail "Release appでSURequireSignedFeedが有効ではありません"
[ "$VERIFY_BEFORE_EXTRACTION" = "true" ] \
  || fail "Release appでSUVerifyUpdateBeforeExtractionが有効ではありません"

PROJECT_VERSION=$(/usr/bin/awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
  "$ROOT/project.yml")
PROJECT_BUILD=$(/usr/bin/awk '$1 == "CURRENT_PROJECT_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
  "$ROOT/project.yml")
[ "$PROJECT_VERSION" = "$RELEASE_VERSION" ] \
  || fail "project.ymlとRelease appのversionが一致しません"
[ "$PROJECT_BUILD" = "$RELEASE_BUILD" ] \
  || fail "project.ymlとRelease appのbuild numberが一致しません"

cleanup_mount || fail "Release DMGのmountを解除できません"

ARCHIVES_DIR="$WORK_DIR/archives"
mkdir "$ARCHIVES_DIR"
ARCHIVE_DMG="$ARCHIVES_DIR/$DMG_NAME"
GENERATED_APPCAST="$ARCHIVES_DIR/appcast.xml"
cp -p "$PUBLIC_DMG" "$ARCHIVE_DMG"

PUBLISHED_AT=$(jq -er '.publishedAt' "$RELEASE_JSON")
if [[ "$PUBLISHED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  RELEASE_TOUCH_TIME=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$PUBLISHED_AT" '+%Y%m%d%H%M.%S') \
    || fail "Release公開日時を変換できません: $PUBLISHED_AT"
  touch -t "$RELEASE_TOUCH_TIME" "$ARCHIVE_DMG"
else
  fail "GitHub ReleaseのpublishedAt形式が不正です: $PUBLISHED_AT"
fi

EXISTING_APPCAST=""
if [ -f "$OUTPUT" ]; then
  EXISTING_APPCAST="$WORK_DIR/existing-appcast.xml"
  cp "$OUTPUT" "$EXISTING_APPCAST"
  cp "$OUTPUT" "$GENERATED_APPCAST"
fi

"$GENERATE_APPCAST" \
  --account "$KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$PUBLIC_DOWNLOAD_BASE/$TAG/" \
  --link "$PRODUCT_URL" \
  --maximum-deltas 0 \
  --maximum-versions 0 \
  -o "$GENERATED_APPCAST" \
  "$ARCHIVES_DIR"

[ -f "$GENERATED_APPCAST" ] || fail "appcastが生成されませんでした"
[ "$(find "$ARCHIVES_DIR" -type f -name '*.delta' | wc -l | tr -d ' ')" = "0" ] \
  || fail "delta updateが生成されました"
xmllint --noout "$GENERATED_APPCAST" \
  || fail "生成appcastがwell-formed XMLではありません"

FEED_VALIDATION="$WORK_DIR/feed-validation.txt"
python3 - \
  "$EXISTING_APPCAST" \
  "$GENERATED_APPCAST" \
  "$RELEASE_BUILD" \
  "$RELEASE_VERSION" \
  "$EXPECTED_DOWNLOAD_URL" \
  "$PRODUCT_URL" \
  "$PUBLIC_DMG_SIZE" \
  >"$FEED_VALIDATION" <<'PY'
import base64
import collections
import sys
import xml.etree.ElementTree as ET

old_path, new_path, build, version, download_url, product_url, length = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def text(item, name):
    node = item.find(f"{{{sparkle}}}{name}")
    return "" if node is None or node.text is None else node.text.strip()


def item_key(item):
    enclosure = item.find("enclosure")
    return (
        text(item, "version"),
        text(item, "shortVersionString"),
        "" if enclosure is None else enclosure.get("url", ""),
    )


new_root = ET.parse(new_path).getroot()
new_items = new_root.findall("./channel/item")
if not new_items:
    raise SystemExit("generated appcast has no items")

old_items = []
if old_path:
    old_root = ET.parse(old_path).getroot()
    old_items = old_root.findall("./channel/item")
    old_counts = collections.Counter(map(item_key, old_items))
    new_counts = collections.Counter(map(item_key, new_items))
    missing = old_counts - new_counts
    if missing:
        raise SystemExit(f"existing appcast history was not preserved: {list(missing)}")

matches = [
    item
    for item in new_items
    if text(item, "version") == build
    and text(item, "shortVersionString") == version
]
if len(matches) != 1:
    raise SystemExit(f"expected one current item, found {len(matches)}")

current = matches[0]
link = current.findtext("link", default="").strip()
if link != product_url:
    raise SystemExit(f"unexpected product link: {link}")
if current.find(f"{{{sparkle}}}deltas") is not None:
    raise SystemExit("current item unexpectedly contains delta updates")

enclosure = current.find("enclosure")
if enclosure is None:
    raise SystemExit("current item has no enclosure")
if enclosure.get("url") != download_url:
    raise SystemExit(f"unexpected enclosure URL: {enclosure.get('url')}")
if enclosure.get("length") != length:
    raise SystemExit(f"unexpected enclosure length: {enclosure.get('length')}")
if enclosure.get("type") != "application/octet-stream":
    raise SystemExit(f"unexpected enclosure type: {enclosure.get('type')}")

signature = enclosure.get(f"{{{sparkle}}}edSignature", "")
try:
    signature_bytes = base64.b64decode(signature, validate=True)
except ValueError as error:
    raise SystemExit(f"invalid enclosure signature encoding: {error}") from error
if len(signature_bytes) != 64:
    raise SystemExit("enclosure signature is not an Ed25519 signature")

print(signature)
print(len(old_items))
print(len(new_items))
PY

ENCLOSURE_SIGNATURE=$(sed -n '1p' "$FEED_VALIDATION")
OLD_ITEM_COUNT=$(sed -n '2p' "$FEED_VALIDATION")
NEW_ITEM_COUNT=$(sed -n '3p' "$FEED_VALIDATION")
[ -n "$ENCLOSURE_SIGNATURE" ] || fail "enclosure署名を取得できません"

"$SIGN_UPDATE" --account "$KEYCHAIN_ACCOUNT" --verify "$GENERATED_APPCAST" >/dev/null \
  || fail "生成appcastのfeed署名を検証できません"
"$SIGN_UPDATE" \
  --account "$KEYCHAIN_ACCOUNT" \
  --verify "$PUBLIC_DMG" "$ENCLOSURE_SIGNATURE" >/dev/null \
  || fail "生成appcastのenclosure署名を検証できません"

stage_public_release_assets

OUTPUT_TEMP=$(mktemp "$OUTPUT_PARENT/.${OUTPUT_NAME}.XXXXXX")
cp "$GENERATED_APPCAST" "$OUTPUT_TEMP"
chmod 644 "$OUTPUT_TEMP"
mv "$OUTPUT_TEMP" "$OUTPUT"

printf 'appcast ready: %s\n' "$OUTPUT"
printf '  release: %s %s (build %s)\n' "$REPOSITORY" "$TAG" "$RELEASE_BUILD"
printf '  public dmg: %s\n' "$EXPECTED_DOWNLOAD_URL"
printf '  public assets: %s (%s)\n' "$PUBLIC_ASSETS_ROOT/$TAG" "$ASSET_STAGE_RESULT"
printf '  dmg sha256: %s\n' "$PUBLIC_DMG_SHA"
printf '  history: %s existing item(s), %s total item(s)\n' \
  "$OLD_ITEM_COUNT" "$NEW_ITEM_COUNT"
printf '  deltas: 0\n'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
