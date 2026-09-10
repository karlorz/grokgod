#!/bin/sh
set -eu

# test_0011_apply.sh: Verify 0011-ask-question-timeout-action.patch exists
# and applies cleanly against PINNED_BASE_SHA after 0001-0010 (docs/persist
# already carry 0004/0008 hunks).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0011="$REPO_ROOT/patches/0011-ask-question-timeout-action.patch"
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

echo "=== Running 0011 Ask-Question timeout_action Patch Tests ==="

if [ ! -s "$PATCH_0011" ]; then
  echo "FAIL: 0011 patch file not found or empty: $PATCH_0011" >&2
  exit 1
fi
echo "PASS: Patch 0011 file exists and is non-empty"

grep -q "timeout_action" "$PATCH_0011" || { echo "FAIL: Missing timeout_action in 0011"; exit 1; }
grep -q "GROK_ASK_USER_QUESTION_TIMEOUT_ACTION" "$PATCH_0011" || { echo "FAIL: Missing TIMEOUT_ACTION env in 0011"; exit 1; }
grep -q "timeout_recommended_text" "$PATCH_0011" || { echo "FAIL: Missing timeout_recommended_text in 0011"; exit 1; }
grep -q "recommended_labels" "$PATCH_0011" || { echo "FAIL: Missing recommended_labels (multi-select all marked) in 0011"; exit 1; }
grep -q "timeout_recommended_multi_select_picks_all" "$PATCH_0011" || { echo "FAIL: Missing multi-select all-recommended tests in 0011"; exit 1; }
grep -q "crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs" "$PATCH_0011" || { echo "FAIL: Missing ask_user_question/mod.rs diff in 0011"; exit 1; }
grep -q "crates/codegen/xai-grok-shell/src/util/config/resolve/toolset.rs" "$PATCH_0011" || { echo "FAIL: Missing toolset resolver diff in 0011"; exit 1; }
if grep -q "SetAskUserQuestionTimeoutAction" "$PATCH_0011"; then
  echo "FAIL: 0011 must not add a /settings row" >&2
  exit 1
fi

if [ -d "$REAL_GROK_BUILD/.git" ]; then
  echo "Testing patch application against real grok-build checkout..."
  TMP_WT="$(mktemp -d -t grokgod-test-0011-wt-XXXXXX)"
  trap 'rm -rf "$TMP_WT"' EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHORT" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHORT" >&2
    exit 1
  }
  CLEANUP_WT="git -C $REAL_GROK_BUILD worktree remove --force $TMP_WT >/dev/null 2>&1 || rm -rf $TMP_WT"
  trap 'eval "$CLEANUP_WT"' EXIT INT TERM

  for pred in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$pred" ] || continue
    base="$(basename "$pred")"
    num="${base%%-*}"
    case "$num" in
      *[!0-9]*) continue ;;
    esac
    stripped="$(printf '%s' "$num" | sed 's/^0*//')"
    [ -n "$stripped" ] || continue
    [ "$stripped" -le 10 ] || continue
    git -C "$TMP_WT" apply "$pred" || {
      echo "FAIL: predecessor patch failed in series: $base" >&2
      exit 1
    }
  done

  git -C "$TMP_WT" apply --check "$PATCH_0011" || {
    echo "FAIL: 0011 patch failed to apply after 0001-0010 on $PIN_SHORT" >&2
    exit 1
  }
  echo "PASS: Patch 0011 applies cleanly after 0001-0010 on $PIN_SHORT"

  eval "$CLEANUP_WT"
  trap - EXIT INT TERM
else
  echo "SKIP: Real grok-build checkout not available at $REAL_GROK_BUILD"
fi

echo "=== Patch 0011 Tests Passed ==="
