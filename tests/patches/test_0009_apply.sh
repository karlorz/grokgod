#!/bin/sh
set -eu

# test_0009_apply.sh: Verify 0009-deepseek-chat-fix.patch exists
# and applies cleanly against PINNED_BASE_SHA after 0001-0008.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0009="$REPO_ROOT/patches/0009-deepseek-chat-fix.patch"
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

echo "=== Running 0009 DeepSeek Chat Fix Patch Tests ==="

if [ ! -s "$PATCH_0009" ]; then
  echo "FAIL: 0009 patch file not found or empty: $PATCH_0009" >&2
  exit 1
fi
echo "PASS: Patch 0009 file exists and is non-empty"

grep -q "deserialize_null_default" "$PATCH_0009" || { echo "FAIL: Missing deserialize_null_default in 0009"; exit 1; }
grep -q "test_chat_completion_chunk_deserializes_null_usage_detail_ints" "$PATCH_0009" || { echo "FAIL: Missing null-usage regression test in 0009"; exit 1; }
grep -q "crates/codegen/xai-grok-sampling-types/src/types.rs" "$PATCH_0009" || { echo "FAIL: Missing types.rs diff in 0009"; exit 1; }
grep -q "reasoning_tokens" "$PATCH_0009" || { echo "FAIL: Missing reasoning_tokens in 0009"; exit 1; }

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0009-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  # 0009 is independent of 0001-0008 (sampling-types only) but install.sh
  # consumes the series in order, so verify cumulative application.
  for pred in "$REPO_ROOT"/patches/000[1-8]*.patch; do
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed in series: $(basename "$pred")" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0009" || {
    echo "FAIL: 0009 patch failed to apply after 0001-0008 on $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0009 applies cleanly after 0001-0008 on $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0009 Tests Passed ==="
