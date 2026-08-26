#!/bin/sh
set -eu

# test_0003_apply.sh: Verify that patch 0003-session-persist-single.patch
# exists and applies cleanly on top of 0001 and 0002 against base commit c2ad97f8.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0001="$REPO_ROOT/patches/0001-normalize-plugin-skill-join.patch"
PATCH_0002="$REPO_ROOT/patches/0002-plan-mode-extra-writable.patch"
PATCH_0003="$REPO_ROOT/patches/0003-session-persist-single.patch"

REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
if [ "${CI:-0}" = "1" ]; then
  REAL_GROK_BUILD="/nonexistent"
fi

echo "=== Running 0003 Session Persist Single Patch Tests ==="

# 1. Verify patch file exists and is non-empty
if [ ! -s "$PATCH_0003" ]; then
  echo "FAIL: 0003 patch file not found or empty: $PATCH_0003" >&2
  exit 1
fi
echo "PASS: Patch 0003 file exists and is non-empty"

# 2. Verify patch targets expected files
grep -q "crates/codegen/xai-grok-config-types/src/lib.rs" "$PATCH_0003" || { echo "FAIL: Missing config-types diff in 0003"; exit 1; }
grep -q "crates/codegen/xai-grok-config/src/config_override.rs" "$PATCH_0003" || { echo "FAIL: Missing config_override diff in 0003"; exit 1; }
grep -q "crates/codegen/xai-grok-shell/src/agent/config.rs" "$PATCH_0003" || { echo "FAIL: Missing agent config diff in 0003"; exit 1; }
grep -q "crates/codegen/xai-grok-shell/src/util/config/persist_tests.rs" "$PATCH_0003" || { echo "FAIL: Missing persist_tests in 0003"; exit 1; }
echo "PASS: Patch 0003 touches expected files"

TMP_ROOT="$(mktemp -d)"
GB_WORKTREE="$TMP_ROOT/gb_worktree"

cleanup() {
  set +e
  if [ -d "$GB_WORKTREE" ] && [ -d "$REAL_GROK_BUILD/.git" ]; then
    git -C "$REAL_GROK_BUILD" worktree remove --force "$GB_WORKTREE" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

# Setup GB_WORKTREE fixture
if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Creating test worktree from $REAL_GROK_BUILD at commit c2ad97f8..."
  git -C "$REAL_GROK_BUILD" worktree add --detach "$GB_WORKTREE" c2ad97f8 >/dev/null 2>&1
else
  echo "Building fixture git repository for CI..."
  PIN_SHA="c2ad97f87aea4303b6000a2c22128bc91ee76c9b"
  RAW_BASE="https://raw.githubusercontent.com/xai-org/grok-build/${PIN_SHA}"
  PATCH_PATHS="$(
    grep -h '^diff --git ' "$REPO_ROOT"/patches/*.patch 2>/dev/null \
      | awk '{print $3}' \
      | sed 's#^a/##' \
      | sort -u
  )"
  for rel in $PATCH_PATHS; do
    mkdir -p "$GB_WORKTREE/$(dirname "$rel")"
    if ! curl -fsSL "$RAW_BASE/$rel" -o "$GB_WORKTREE/$rel"; then
      echo "Warning: curl failed for $rel, creating empty fallback"
      : > "$GB_WORKTREE/$rel"
    fi
  done
  git -C "$GB_WORKTREE" init -b main >/dev/null 2>&1
  git -C "$GB_WORKTREE" config user.name "CI"
  git -C "$GB_WORKTREE" config user.email "ci@example.com"
  git -C "$GB_WORKTREE" add .
  git -C "$GB_WORKTREE" commit -m "initial c2ad97f8 fixture" >/dev/null 2>&1
fi

# 3. Test sequential apply: 0001 -> 0002 -> 0003
echo "Testing sequential apply of 0001, 0002, 0003..."
git -C "$GB_WORKTREE" apply --check "$PATCH_0001"
git -C "$GB_WORKTREE" apply "$PATCH_0001"

git -C "$GB_WORKTREE" apply --check "$PATCH_0002"
git -C "$GB_WORKTREE" apply "$PATCH_0002"

git -C "$GB_WORKTREE" apply --check "$PATCH_0003"
git -C "$GB_WORKTREE" apply "$PATCH_0003"
echo "PASS: 0001 + 0002 + 0003 apply cleanly in sequence"

# 4. Test reverse in LIFO order
echo "Testing reverse apply (0003, 0002, 0001)..."
git -C "$GB_WORKTREE" apply -R --check "$PATCH_0003"
git -C "$GB_WORKTREE" apply -R "$PATCH_0003"

git -C "$GB_WORKTREE" apply -R --check "$PATCH_0002"
git -C "$GB_WORKTREE" apply -R "$PATCH_0002"

git -C "$GB_WORKTREE" apply -R --check "$PATCH_0001"
git -C "$GB_WORKTREE" apply -R "$PATCH_0001"

git -C "$GB_WORKTREE" diff --quiet || { echo "FAIL: Working tree not clean after reverse apply"; exit 1; }
echo "PASS: Reversals succeed and leave tree clean"

echo "=== All 0003 patch apply tests passed! ==="
