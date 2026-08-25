#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=prepare-appcast.sh
source "$ROOT/scripts/prepare-appcast.sh"

TEST_BASE=${TMPDIR:-/tmp}
TEST_BASE=${TEST_BASE%/}
TEST_BASE=$(cd "$TEST_BASE" && pwd -P)
TEST_ROOT=$(mktemp -d "$TEST_BASE/ai-usage-appcast-test.XXXXXX")

cleanup_test() {
  case "$TEST_ROOT" in
    "$TEST_BASE"/ai-usage-appcast-test.*)
      rm -rf -- "$TEST_ROOT"
      ;;
    *)
      printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2
      exit 1
      ;;
  esac
}
trap cleanup_test EXIT

PUBLIC_ASSETS_ROOT="$TEST_ROOT/public/ai-usage/releases"
mkdir -p "$PUBLIC_ASSETS_ROOT" "$TEST_ROOT/source"
PUBLIC_ASSETS_ROOT=$(canonicalize_public_assets_root "$PUBLIC_ASSETS_ROOT")

TAG="v1.2.3"
DMG_NAME="AIUsage-1.2.3.dmg"
CHECKSUM_NAME="$DMG_NAME.sha256"
RELEASE_DMG="$TEST_ROOT/source/$DMG_NAME"
RELEASE_CHECKSUM="$TEST_ROOT/source/$CHECKSUM_NAME"
printf 'signed test dmg\n' >"$RELEASE_DMG"
printf 'test checksum\n' >"$RELEASE_CHECKSUM"

PUBLISHED_AT_TEST_SOURCE="$TEST_ROOT/source/published-at-source.dmg"
PUBLISHED_AT_TEST_FILE="$TEST_ROOT/source/published-at-archive.dmg"
PUBLISHED_AT_SOURCE_VALUE="2026-08-25T20:18:10Z"
PUBLISHED_AT_TEST_VALUE="2026-08-25T20:30:31Z"
printf 'published-at test\n' >"$PUBLISHED_AT_TEST_SOURCE"
TZ=UTC0 /usr/bin/touch -m -d \
  "$PUBLISHED_AT_SOURCE_VALUE" "$PUBLISHED_AT_TEST_SOURCE"
EXPECTED_SOURCE_BIRTH_EPOCH=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$PUBLISHED_AT_SOURCE_VALUE" '+%s')
ACTUAL_SOURCE_BIRTH_EPOCH=$(stat -f '%B' "$PUBLISHED_AT_TEST_SOURCE")
if [ "$ACTUAL_SOURCE_BIRTH_EPOCH" != "$EXPECTED_SOURCE_BIRTH_EPOCH" ]; then
  printf 'Could not prepare source creation timestamp %s; got %s.\n' \
    "$EXPECTED_SOURCE_BIRTH_EPOCH" "$ACTUAL_SOURCE_BIRTH_EPOCH" >&2
  exit 1
fi
TZ=Asia/Tokyo copy_release_archive_for_appcast \
  "$PUBLISHED_AT_TEST_SOURCE" \
  "$PUBLISHED_AT_TEST_FILE" \
  "$PUBLISHED_AT_TEST_VALUE"
EXPECTED_PUBLISHED_AT_EPOCH=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
  "$PUBLISHED_AT_TEST_VALUE" '+%s')
ACTUAL_PUBLISHED_AT_EPOCH=$(stat -f '%m' "$PUBLISHED_AT_TEST_FILE")
if [ "$ACTUAL_PUBLISHED_AT_EPOCH" != "$EXPECTED_PUBLISHED_AT_EPOCH" ]; then
  printf 'Expected release timestamp %s, got %s.\n' \
    "$EXPECTED_PUBLISHED_AT_EPOCH" "$ACTUAL_PUBLISHED_AT_EPOCH" >&2
  exit 1
fi
ACTUAL_PUBLISHED_AT_BIRTH_EPOCH=$(stat -f '%B' "$PUBLISHED_AT_TEST_FILE")
if [ "$ACTUAL_PUBLISHED_AT_BIRTH_EPOCH" != "$EXPECTED_PUBLISHED_AT_EPOCH" ]; then
  printf 'Expected release creation timestamp %s, got %s.\n' \
    "$EXPECTED_PUBLISHED_AT_EPOCH" "$ACTUAL_PUBLISHED_AT_BIRTH_EPOCH" >&2
  exit 1
fi
if (set_release_archive_mtime '2026-08-25T20:30:31+00:00' \
    "$PUBLISHED_AT_TEST_FILE") >/dev/null 2>&1; then
  printf 'Expected a non-GitHub timestamp format to be rejected.\n' >&2
  exit 1
fi

assert_cloudflare_asset_size "$RELEASE_DMG"
assert_cloudflare_asset_size "$RELEASE_CHECKSUM"

stage_public_release_assets
[ "$ASSET_STAGE_RESULT" = "created" ]
cmp -s "$RELEASE_DMG" "$PUBLIC_ASSETS_ROOT/$TAG/$DMG_NAME"
cmp -s "$RELEASE_CHECKSUM" "$PUBLIC_ASSETS_ROOT/$TAG/$CHECKSUM_NAME"

stage_public_release_assets
[ "$ASSET_STAGE_RESULT" = "unchanged" ]

printf 'different checksum\n' >"$PUBLIC_ASSETS_ROOT/$TAG/$CHECKSUM_NAME"
if (trap cleanup EXIT; stage_public_release_assets >/dev/null 2>&1); then
  printf 'Expected changed versioned assets to be rejected.\n' >&2
  exit 1
fi

if (canonicalize_public_assets_root "$TEST_ROOT/public/ai-usage/../ai-usage/releases") \
    >/dev/null 2>&1; then
  printf 'Expected a non-canonical public assets path to be rejected.\n' >&2
  exit 1
fi

CLOUDFLARE_MAX_STATIC_ASSET_BYTES=$(stat -f '%z' "$RELEASE_DMG")
if (assert_cloudflare_asset_size "$RELEASE_DMG") >/dev/null 2>&1; then
  printf 'Expected an asset at the conservative size boundary to be rejected.\n' >&2
  exit 1
fi

printf 'prepare-appcast staging tests passed\n'
