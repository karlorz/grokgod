#!/bin/sh
set -eu

# test_0010_apply.sh: Verify 0010-deepseek-chat-compact-lenient.patch exists
# and applies cleanly against PINNED_BASE_SHA after 0001-0009 (shares
# client.rs with 0006; must not be checked against a clean pin).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0010="$REPO_ROOT/patches/0010-deepseek-chat-compact-lenient.patch"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SCRIPT" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SCRIPT" >&2
  exit 1
fi
PIN_SHORT="$(printf '%s' "$PIN_SHA" | cut -c1-8)"

REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
if [ "${CI:-0}" = "1" ]; then
  REAL_GROK_BUILD="/nonexistent"
fi

echo "=== Running 0010 DeepSeek Chat Compact Lenient Patch Tests ==="

if [ ! -s "$PATCH_0010" ]; then
  echo "FAIL: 0010 patch file not found or empty: $PATCH_0010" >&2
  exit 1
fi
echo "PASS: Patch 0010 file exists and is non-empty"

grep -q "deserialize_chat_completion_chunk" "$PATCH_0010" || { echo "FAIL: Missing deserialize_chat_completion_chunk in 0010"; exit 1; }
grep -q "sanitize_chat_completion_chunk_compact" "$PATCH_0010" || { echo "FAIL: Missing sanitize_chat_completion_chunk_compact in 0010"; exit 1; }
grep -q "crates/codegen/xai-grok-sampler/src/client.rs" "$PATCH_0010" || { echo "FAIL: Missing client.rs diff in 0010"; exit 1; }
grep -q "deserialize_chat_completion_chunk_defaults_missing_choice_index" "$PATCH_0010" || { echo "FAIL: Missing missing-index regression test in 0010"; exit 1; }
if grep -q "ChatChunkChoice" "$PATCH_0010" && grep -q "deserialize_null_default" "$PATCH_0010"; then
  echo "FAIL: 0010 must not be a per-field ChatChunkChoice serde attr patch" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0010-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  # Numeric prefix filter: glob `000[1-9]*` also matches `0010-*.patch`.
  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 9 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed in series: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0010" || {
    echo "FAIL: 0010 patch failed to apply after 0001-0009 on $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0010 applies cleanly after 0001-0009 on $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0010 Tests Passed ==="
