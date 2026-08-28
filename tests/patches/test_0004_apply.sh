#!/bin/sh
set -eu

# test_0004_apply.sh: Verify 0004-disable-builtin-deep-research.patch exists
# and applies cleanly on top of 0001-0003 against PINNED_BASE_SHA.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0001="$REPO_ROOT/patches/0001-normalize-plugin-skill-join.patch"
PATCH_0002="$REPO_ROOT/patches/0002-plan-mode-extra-writable.patch"
PATCH_0003="$REPO_ROOT/patches/0003-session-persist-single.patch"
PATCH_0004="$REPO_ROOT/patches/0004-disable-builtin-deep-research.patch"
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

echo "=== Running 0004 Disable Builtin Deep-Research Patch Tests ==="

if [ ! -s "$PATCH_0004" ]; then
  echo "FAIL: 0004 patch file not found or empty: $PATCH_0004" >&2
  exit 1
fi
echo "PASS: Patch 0004 file exists and is non-empty"

grep -q "crates/codegen/xai-grok-shell/src/agent/config.rs" "$PATCH_0004" || { echo "FAIL: Missing agent config diff in 0004"; exit 1; }
grep -q "crates/codegen/xai-grok-shell/src/session/slash_commands.rs" "$PATCH_0004" || { echo "FAIL: Missing slash_commands diff in 0004"; exit 1; }
grep -q "crates/codegen/xai-grok-shell/src/session/workflow/registry.rs" "$PATCH_0004" || { echo "FAIL: Missing registry diff in 0004"; exit 1; }
grep -q "crates/codegen/xai-grok-pager/src/settings/defs.rs" "$PATCH_0004" || { echo "FAIL: Missing settings defs diff in 0004"; exit 1; }
grep -q "ToggleSelectedBuiltinWorkflow" "$PATCH_0004" || { echo "FAIL: Missing /plugin Workflows Space toggle in 0004"; exit 1; }
grep -q "workflows.builtins" "$PATCH_0004" || { echo "FAIL: Missing workflows.builtins in 0004"; exit 1; }
echo "PASS: Patch 0004 touches expected files"

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

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Creating test worktree from $REAL_GROK_BUILD at commit $PIN_SHORT..."
  git -C "$REAL_GROK_BUILD" worktree add --detach "$GB_WORKTREE" "$PIN_SHA" >/dev/null 2>&1
else
  echo "Building fixture git repository for CI..."
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
  git -C "$GB_WORKTREE" commit -m "initial $PIN_SHORT fixture" >/dev/null 2>&1
fi

echo "Testing sequential apply of 0001, 0002, 0003, 0004..."
git -C "$GB_WORKTREE" apply --check "$PATCH_0001"
git -C "$GB_WORKTREE" apply "$PATCH_0001"

git -C "$GB_WORKTREE" apply --check "$PATCH_0002"
git -C "$GB_WORKTREE" apply "$PATCH_0002"

git -C "$GB_WORKTREE" apply --check "$PATCH_0003"
git -C "$GB_WORKTREE" apply "$PATCH_0003"

git -C "$GB_WORKTREE" apply --check "$PATCH_0004"
git -C "$GB_WORKTREE" apply "$PATCH_0004"
echo "PASS: 0001 + 0002 + 0003 + 0004 apply cleanly in sequence"

echo "Testing reverse apply (0004, 0003, 0002, 0001)..."
git -C "$GB_WORKTREE" apply -R --check "$PATCH_0004"
git -C "$GB_WORKTREE" apply -R "$PATCH_0004"

git -C "$GB_WORKTREE" apply -R --check "$PATCH_0003"
git -C "$GB_WORKTREE" apply -R "$PATCH_0003"

git -C "$GB_WORKTREE" apply -R --check "$PATCH_0002"
git -C "$GB_WORKTREE" apply -R "$PATCH_0002"

git -C "$GB_WORKTREE" apply -R --check "$PATCH_0001"
git -C "$GB_WORKTREE" apply -R "$PATCH_0001"

git -C "$GB_WORKTREE" diff --quiet || { echo "FAIL: Working tree not clean after reverse apply"; exit 1; }
echo "PASS: Reversals succeed and leave tree clean"

echo "=== All 0004 patch apply tests passed! ==="
