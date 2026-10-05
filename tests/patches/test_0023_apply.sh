#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_0023="$REPO_ROOT/patches/0023-usage-limit-retry-prompt-lifetime.patch"
PIN_SHA="$(awk -F '\t' '$1 == "base-sha" { print $2 }' "$REPO_ROOT/patches/registry.tsv")"
[ -n "$PIN_SHA" ] || { echo "FAIL: patch registry base-sha missing" >&2; exit 1; }
REAL_GROK_BUILD="${REAL_GROK_BUILD:-/Users/karlchow/Desktop/code/grok-build}"
[ "${CI:-0}" = "1" ] && REAL_GROK_BUILD="/nonexistent"

echo "=== Running 0023 usage-limit retry prompt lifetime patch tests ==="
[ -s "$PATCH_0023" ] || { echo "FAIL: 0023 patch missing or empty" >&2; exit 1; }

python3 - "$PATCH_0023" <<'PY'
import re
import sys
from pathlib import Path

patch = Path(sys.argv[1]).read_text()
files = re.findall(r"^diff --git a/(.*?) b/", patch, re.MULTILINE)
assert len(files) == len(set(files)), "duplicate file diff"
assert len(files) == 21, f"unexpected changed-file count: {files!r}"
assert all(path.startswith("crates/codegen/xai-grok-pager/src/") for path in files), files
added = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
for needle in (
    "pub usage_limit_retry_prompt: Option<InFlightPrompt>",
    "pub fn capture_in_flight_prompt",
    "self.usage_limit_retry_prompt = Some(prompt.clone())",
    "self.in_flight_prompt = Some(prompt)",
    "!was_cancelling",
    ".usage_limit_retry_prompt",
    ".or_else(|| agent.session.in_flight_prompt.take())",
    "credit_limit_retry_after_assistant_activity_resends_exact_prompt_once",
    "credit_limit_tool_activity_autocompact_retains_combined_images_and_chips",
    "credit_limit_free_usage_after_activity_switch_resends_once",
    "credit_limit_retry_snapshot_clears_on_completion_failure_cancel_and_reset",
    "credit_limit_adopted_prompt_captures_both_plain_and_combined_payloads",
    "SessionUpdate::AutoCompactStarted",
    "SessionUpdate::AutoCompactCompleted",
    "Effect::SendPromptBlocks",
):
    assert needle in added, f"missing retry lifetime contract: {needle}"
queue_diff = patch.split("diff --git a/crates/codegen/xai-grok-pager/src/app/dispatch/queue.rs", 1)[1].split("diff --git", 1)[0]
assert queue_diff.count(".capture_in_flight_prompt(") == 3, "all three capture sites must retain the snapshot"
assert added.count("usage_limit_retry_prompt: None") >= 10, "session constructors must initialize snapshot"
assert added.count("usage_limit_retry_prompt = None") >= 4, "turn/session resets must clear snapshot"
print("PASS: 0023 retry payload, cancellation, reset, and regression contracts")
PY

if git -C "$REAL_GROK_BUILD" rev-parse --git-dir >/dev/null 2>&1; then
  TMP_WT="$(mktemp -d -t grokgod-test-0023-wt-XXXXXX)"
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
    [ "$predecessor" = "$PATCH_0023" ] && break
    git -C "$TMP_WT" apply --check "$predecessor"
    git -C "$TMP_WT" apply "$predecessor"
  done
  git -C "$TMP_WT" apply --check "$PATCH_0023"
  git -C "$TMP_WT" apply "$PATCH_0023"
  git -C "$TMP_WT" diff --check
  echo "PASS: 0023 applies after full predecessor stack at $PIN_SHA"
else
  echo "SKIP: real grok-build checkout unavailable"
fi

echo "=== Patch 0023 tests passed ==="
