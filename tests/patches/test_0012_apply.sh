#!/bin/sh
set -eu

# Verify the portable protoc dependency-output patch exists and applies after
# the preceding patch series.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0012="$REPO_ROOT/patches/0012-protoc-dependency-output-portable.patch"
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

echo "=== Running 0012 Portable protoc Patch Tests ==="

if [ ! -s "$PATCH_0012" ]; then
  echo "FAIL: 0012 patch file not found or empty: $PATCH_0012" >&2
  exit 1
fi

grep -q 'NamedTempFile' "$PATCH_0012" || { echo "FAIL: Missing temporary dependency outputs"; exit 1; }
grep -q 'split_once(": ")' "$PATCH_0012" || { echo "FAIL: Missing Windows-drive-safe dependency parser"; exit 1; }
if grep '^+' "$PATCH_0012" | grep -q 'dependency_out=/dev/stdout'; then
  echo "FAIL: 0012 must not add Unix-only dependency output" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  TMP_WT="$(mktemp -d -t grokgod-test-0012-wt-XXXXXX)"
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }

  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    [ "$pred" = "$PATCH_0012" ] && continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed in series: $(basename "$pred")" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0012" || {
    echo "FAIL: 0012 patch failed to apply after 0001-0011 on $PIN_SHORT" >&2
    exit 1
  }
  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0012 Tests Passed ==="
