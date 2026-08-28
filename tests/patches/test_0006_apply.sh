#!/bin/sh
set -eu

# test_0006_apply.sh: Verify 0006-web-search-call-tolerant-parse.patch exists
# and applies cleanly against PINNED_BASE_SHA.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0006="$REPO_ROOT/patches/0006-web-search-call-tolerant-parse.patch"
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

echo "=== Running 0006 Web Search Call Tolerant Parse Patch Tests ==="

if [ ! -s "$PATCH_0006" ]; then
  echo "FAIL: 0006 patch file not found or empty: $PATCH_0006" >&2
  exit 1
fi
echo "PASS: Patch 0006 file exists and is non-empty"

grep -q "sanitize_search_call_action" "$PATCH_0006" || { echo "FAIL: Missing sanitize_search_call_action in 0006"; exit 1; }
grep -q "crates/codegen/xai-grok-sampler/src/client.rs" "$PATCH_0006" || { echo "FAIL: Missing client.rs diff in 0006"; exit 1; }

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0006-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  git -C "$TMP_WT" apply --check "$PATCH_0006" || {
    echo "FAIL: 0006 patch failed to apply cleanly to $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0006 applies cleanly to $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0006 Tests Passed ==="
