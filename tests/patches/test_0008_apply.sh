#!/bin/sh
set -eu

# test_0008_apply.sh: Verify 0008-claude-permissions-import-gate.patch exists
# and applies cleanly against PINNED_BASE_SHA.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0008="$REPO_ROOT/patches/0008-claude-permissions-import-gate.patch"
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

echo "=== Running 0008 Claude Permissions Import Gate Patch Tests ==="

if [ ! -s "$PATCH_0008" ]; then
  echo "FAIL: 0008 patch file not found or empty: $PATCH_0008" >&2
  exit 1
fi
echo "PASS: Patch 0008 file exists and is non-empty"

grep -q "GROK_CLAUDE_PERMISSIONS_ENABLED" "$PATCH_0008" || { echo "FAIL: Missing GROK_CLAUDE_PERMISSIONS_ENABLED in 0008"; exit 1; }
grep -q "crates/codegen/xai-grok-tools/src/types/compat.rs" "$PATCH_0008" || { echo "FAIL: Missing compat.rs diff in 0008"; exit 1; }
grep -q "crates/codegen/xai-grok-workspace/src/permission/resolution.rs" "$PATCH_0008" || { echo "FAIL: Missing resolution.rs diff in 0008"; exit 1; }

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0008-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  # Cumulative series in install.sh order. Do not glob `000[1-7]*` — that
  # also matches `0010-*.patch` (`000` + `1` + `0-...`).
  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 7 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed in series: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0008" || {
    echo "FAIL: 0008 patch failed to apply after 0001-0007 on $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0008 applies cleanly after 0001-0007 on $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0008 Tests Passed ==="
