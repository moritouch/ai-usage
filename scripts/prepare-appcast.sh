#!/bin/bash
# 公開済みimmutable GitHub Releaseから、署名済みSparkle appcastを生成する。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_VERSION="2.9.6"
SPARKLE_TOOLS="$ROOT/build/sparkle-tools/$SPARKLE_VERSION/bin"
KEYCHAIN_ACCOUNT="jp.co.forestx.aiusage"
APP_BUNDLE_ID="jp.co.forestx.aiusage"
APP_NAME="AI Usage"
PRODUCT_URL="https://moritouch.com/ai-usage"
FEED_URL="$PRODUCT_URL/appcast.xml"

REPOSITORY=""
TAG=""
OUTPUT=""
WORK_DIR=""
MOUNT_DIR=""
MOUNTED=0
LOCK_DIR="$ROOT/build/appcast.lock"
LOCK_HELD=0

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
    --output /path/to/appcast.xml

The GitHub Release must already be published, non-prerelease, immutable, and
attested. Its notarized AIUsage-X.Y.Z.dmg and matching .sha256 must be identical
to the two files in local dist/. Existing appcast history is preserved.

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

  if [ "$LOCK_HELD" -eq 1 ] && ! rmdir "$LOCK_DIR"; then
    printf 'error: appcast lockを解除できませんでした: %s\n' "$LOCK_DIR" >&2
    if [ "$script_status" -eq 0 ]; then
      script_status=1
    fi
  fi
  exit "$script_status"
}
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

[ -n "$REPOSITORY" ] && [ -n "$TAG" ] && [ -n "$OUTPUT" ] \
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

if ! CANONICAL_REPOSITORY=$(gh repo view "$REPOSITORY" --json nameWithOwner --jq '.nameWithOwner'); then
  fail "GitHub repositoryを取得できません: $REPOSITORY"
fi
[[ "$CANONICAL_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "GitHubが返したrepository名が不正です"
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
  || fail "Releaseは公開済み・stable・immutableで、DMG/checksumの2 assetだけである必要があります"

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
  || fail "公開checksum fileの形式またはfilenameが不正です"
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
  || fail "公開DMGと公開checksumが一致しません"
[ "$PUBLIC_DMG_SHA" = "$GITHUB_DMG_SHA" ] \
  || fail "公開DMGとGitHub asset digestが一致しません"
[ "$PUBLIC_DMG_SHA" = "$LOCAL_DMG_SHA" ] \
  || fail "公開DMGとlocal dist DMGが一致しません"
[ "$LOCAL_DMG_SHA" = "$LOCAL_CHECKSUM_VALUE" ] \
  || fail "local dist DMGとlocal checksumが一致しません"
[ "$PUBLIC_CHECKSUM_SHA" = "$GITHUB_CHECKSUM_SHA" ] \
  || fail "公開checksumとGitHub asset digestが一致しません"
cmp -s "$PUBLIC_CHECKSUM" "$LOCAL_CHECKSUM" \
  || fail "公開checksum fileとlocal checksum fileがbyte単位で一致しません"

GITHUB_DMG_SIZE=$(jq -er --arg name "$DMG_NAME" \
  '.assets[] | select(.name == $name) | .size' "$RELEASE_JSON")
PUBLIC_DMG_SIZE=$(stat -f '%z' "$PUBLIC_DMG")
[ "$PUBLIC_DMG_SIZE" = "$GITHUB_DMG_SIZE" ] \
  || fail "公開DMGのsizeがGitHub metadataと一致しません"

EXPECTED_DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG/$DMG_NAME"
GITHUB_DOWNLOAD_URL=$(jq -er --arg name "$DMG_NAME" \
  '.assets[] | select(.name == $name) | .url' "$RELEASE_JSON")
[ "$GITHUB_DOWNLOAD_URL" = "$EXPECTED_DOWNLOAD_URL" ] \
  || fail "GitHub Release asset URLが固定tag URLと一致しません"

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
  fail "公開DMGを読み取り専用でmountできません"
fi

MOUNTED_APP="$MOUNT_DIR/$APP_NAME.app"
[ -d "$MOUNTED_APP" ] || fail "公開DMGに$APP_NAME.appがありません"
[ "$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')" = "1" ] \
  || fail "公開DMG内のapp bundleが1件ではありません"

codesign --verify --deep --strict --verbose=2 "$MOUNTED_APP" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$MOUNTED_APP" 2>&1 | sed 's/^/    /'
spctl --assess --type execute -vv "$MOUNTED_APP" 2>&1 | sed 's/^/    /'

APP_INFO="$MOUNTED_APP/Contents/Info.plist"
[ -f "$APP_INFO" ] || fail "公開appのInfo.plistがありません"
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
  || fail "公開appのbundle IDが不正です: $RELEASE_BUNDLE_ID"
[ "$RELEASE_VERSION" = "$VERSION" ] \
  || fail "tagと公開appのversionが一致しません: $RELEASE_VERSION"
[[ "$RELEASE_BUILD" =~ ^[0-9]+$ ]] \
  || fail "公開appのbuild numberが数値ではありません: $RELEASE_BUILD"
[ "$RELEASE_FEED_URL" = "$FEED_URL" ] \
  || fail "公開appのSparkle feed URLが不正です: $RELEASE_FEED_URL"
[ "$RELEASE_PUBLIC_KEY" = "$KEYCHAIN_PUBLIC_KEY" ] \
  || fail "公開appのSparkle公開鍵がKeychainと一致しません"
[ "$REQUIRE_SIGNED_FEED" = "true" ] \
  || fail "公開appでSURequireSignedFeedが有効ではありません"
[ "$VERIFY_BEFORE_EXTRACTION" = "true" ] \
  || fail "公開appでSUVerifyUpdateBeforeExtractionが有効ではありません"

PROJECT_VERSION=$(/usr/bin/awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
  "$ROOT/project.yml")
PROJECT_BUILD=$(/usr/bin/awk '$1 == "CURRENT_PROJECT_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
  "$ROOT/project.yml")
[ "$PROJECT_VERSION" = "$RELEASE_VERSION" ] \
  || fail "project.ymlと公開appのversionが一致しません"
[ "$PROJECT_BUILD" = "$RELEASE_BUILD" ] \
  || fail "project.ymlと公開appのbuild numberが一致しません"

cleanup_mount || fail "公開DMGのmountを解除できません"

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
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
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

OUTPUT_TEMP=$(mktemp "$OUTPUT_PARENT/.${OUTPUT_NAME}.XXXXXX")
cp "$GENERATED_APPCAST" "$OUTPUT_TEMP"
chmod 644 "$OUTPUT_TEMP"
mv "$OUTPUT_TEMP" "$OUTPUT"

printf 'appcast ready: %s\n' "$OUTPUT"
printf '  release: %s %s (build %s)\n' "$REPOSITORY" "$TAG" "$RELEASE_BUILD"
printf '  dmg sha256: %s\n' "$PUBLIC_DMG_SHA"
printf '  history: %s existing item(s), %s total item(s)\n' \
  "$OLD_ITEM_COUNT" "$NEW_ITEM_COUNT"
printf '  deltas: 0\n'
