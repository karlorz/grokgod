#!/bin/sh
set -eu

# test_0007_apply.sh: Verify 0007-hosted-web-search-splice-decouple.patch exists
# and applies cleanly against PINNED_BASE_SHA.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0007="$REPO_ROOT/patches/0007-hosted-web-search-splice-decouple.patch"
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

echo "=== Running 0007 Hosted Web Search Splice Decouple Patch Tests ==="

if [ ! -s "$PATCH_0007" ]; then
  echo "FAIL: 0007 patch file not found or empty: $PATCH_0007" >&2
  exit 1
fi
echo "PASS: Patch 0007 file exists and is non-empty"

grep -q "hosted_web_search_disabled" "$PATCH_0007" || { echo "FAIL: Missing hosted_web_search_disabled in 0007"; exit 1; }
grep -q "crates/codegen/xai-grok-agent/src/builder.rs" "$PATCH_0007" || { echo "FAIL: Missing builder.rs diff in 0007"; exit 1; }

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0007-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  git -C "$TMP_WT" apply --check "$PATCH_0007" || {
    echo "FAIL: 0007 patch failed to apply cleanly to $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0007 applies cleanly to $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0007 Tests Passed ==="
