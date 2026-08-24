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
