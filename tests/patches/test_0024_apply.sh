#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0024="$REPO_ROOT/patches/0024-content-filter-turn-recovery.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0024 content-filter turn recovery patch tests ==="
[ -s "$PATCH_0024" ] || { echo "FAIL: 0024 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0024" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)), "duplicate file diff"
assert len(files) == 30, f"unexpected changed-file count: {files!r}"
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in (
    'pub struct ContentFilterToml',
    'GROK_CONTENT_FILTER_ACTION',
    'action = "error"',
    'retry_then_error',
    'ContentFilterAction::Error',
    'CONTENT_FILTER_TURN_MESSAGE',
    'content_filter_stashed_prompt',
    'content_filter_model_retry_pending',
    'LocalQuestionKind::ContentFilterRecovery',
    'RetryContentFilterPrompt',
    'OpenContentFilterModelPicker',
    'Switch model & retry',
    'content_filter_error_stashes_prompt_and_opens_recovery_modal',
    'content_filter_try_again_resends_exact_prompt_once',
    'content_filter_switch_model_resends_exact_prompt_once',
    'content_filter_retry_does_not_consume_credit_limit_stash',
    '["compat", "content_filter", "action"]',
    'should_retry: Some(false)',
):
    assert needle in added, f"missing content-filter contract: {needle}"
print("PASS: 0024 config, sampler fail-closed, pager stash/switch contracts")
PY

if git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  TMP_WT="$(mktemp -d -t grokgod-test-0024-wt-XXXXXX)"
  cleanup() {
    git -C "$REAL_GROK_BUILD" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM
  git -C "$REAL_GROK_BUILD" worktree add --detach "$TMP_WT" "$PIN_SHA" >/dev/null 2>&1 || {
    echo "FAIL: could not create detached worktree at $PIN_SHA" >&2
    exit 1
  }
  for predecessor in "$REPO_ROOT"/patches/*.patch; do
    [ -f "$predecessor" ] || continue
    [ "$predecessor" = "$PATCH_0024" ] && break
    git -C "$TMP_WT" apply --check "$predecessor"
    git -C "$TMP_WT" apply "$predecessor"
  done
  git -C "$TMP_WT" apply --check "$PATCH_0024"
  git -C "$TMP_WT" apply "$PATCH_0024"
  git -C "$TMP_WT" diff --check
  echo "PASS: 0024 applies after full predecessor stack at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0024 tests passed ==="
