#!/bin/sh
set -eu

# Verify 0014 exists, contains the required tool image hoist contract, and applies after 0001-0013.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0014="$REPO_ROOT/patches/0014-deepseek-tool-image-hoist.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
[ -n "$PIN_SHA" ] || { echo "FAIL: PINNED_BASE_SHA missing" >&2; exit 1; }
PIN_SHORT="$(printf '%s' "$PIN_SHA" | cut -c1-8)"
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0014 deepseek tool image hoist patch tests ==="
[ -s "$PATCH_0014" ] || { echo "FAIL: 0014 patch missing or empty" >&2; exit 1; }

for needle in \
  'hoist_tool_images' \
  'Attached image(s) from tool result:' \
  'input_modalities' \
  'input_modalities_for' \
  'test_tool_image_hoisting_request_conversion' \
  'test_tool_image_hoisting_mixed_tool_run' \
  'test_tool_image_hoisting_multiple_images_in_single_result' \
  'test_tool_image_hoisting_preserves_both_tool_call_ids' \
  'test_tool_image_hoisting_system_message_untouched'; do
  grep -q "$needle" "$PATCH_0014" || { echo "FAIL: missing 0014 contract: $needle" >&2; exit 1; }
done

if grep -Eiq '(~/\.grok|\.grok/config\.toml)' "$PATCH_0014"; then
  echo "FAIL: 0014 must never edit live ~/.grok or .grok/config.toml" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0014-wt-XXXXXX)"
  CLEANUP="git -C \"$REAL_GROK_BUILD\" worktree remove --force \"$TMP_WT\" >/dev/null 2>&1 || rm -rf \"$TMP_WT\""
  trap 'eval "$CLEANUP"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || { echo "FAIL: could not create verification worktree" >&2; exit 1; }
  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 13 ] || continue
    git -C "$TMP_WT" apply "$pred" || { echo "FAIL: predecessor patch failed: $base" >&2; exit 1; }
  done
  git -C "$TMP_WT" apply --check "$PATCH_0014" || { echo "FAIL: 0014 does not apply after 0001-0013" >&2; exit 1; }
  echo "PASS: 0014 applies after 0001-0013 on $PIN_SHORT"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0014 tests passed ==="
